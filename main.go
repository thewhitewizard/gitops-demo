// Commande demo : un service HTTP minimal dont le seul rôle est de rendre visible,
// dans un terminal, ce que Kubernetes fait pendant un déploiement.
//
// Il expose sa version (injectée au build depuis le SHA du commit) et le nom du pod
// qui répond : pendant un canary, une boucle curl montre donc les deux versions
// cohabiter. Et il s'arrête proprement, ce qui est la condition pour que cette même
// boucle n'affiche aucune erreur.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
)

// version est injectée au build : -ldflags "-X main.version=sha-abc1234".
var version = "dev"

// Délais d'arrêt. Voir shutdown() pour le rôle exact de chacun.
var (
	drainDelay      = envDuration("DRAIN_DELAY", 5*time.Second)
	shutdownTimeout = envDuration("SHUTDOWN_TIMEOUT", 15*time.Second)
)

var startedAt = time.Now()

// draining est fermé dès le SIGTERM. Tant qu'il est ouvert le pod se déclare prêt ;
// une fois fermé, /readyz échoue et Kubernetes sort le pod des endpoints du Service.
var draining = make(chan struct{})

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(log)

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())

	r.GET("/", handleRoot)
	r.GET("/healthz", handleHealthz)
	r.GET("/readyz", handleReadyz)

	srv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,
	}

	// On écoute SIGTERM (envoyé par Kubernetes) et SIGINT (Ctrl-C en local).
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	go func() {
		log.Info("listening", "addr", srv.Addr, "version", version, "pod", env("POD_NAME", "-"))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	stop() // un second signal tue le process sans attendre le drain
	shutdown(srv)
}

// shutdown implémente l'arrêt en deux temps qui rend les déploiements invisibles
// pour les clients.
//
// Le point contre-intuitif : à la réception du SIGTERM, le pod est encore dans les
// endpoints du Service. Traefik et kube-proxy continuent donc de lui envoyer du
// trafic pendant le temps que met la suppression à se propager. Fermer le serveur
// tout de suite produirait exactement les 502 qu'on cherche à éviter.
//
// On échoue donc d'abord les readiness probes, on continue de servir pendant
// drainDelay le temps que la propagation ait lieu, et seulement ensuite on arrête
// d'accepter de nouvelles connexions en laissant finir celles en vol.
func shutdown(srv *http.Server) {
	slog.Info("shutdown: signal reçu, readiness désactivée", "drain", drainDelay)
	close(draining)
	time.Sleep(drainDelay)

	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("shutdown: arrêt forcé", "err", err)
		return
	}
	slog.Info("shutdown: terminé proprement")
}

func handleRoot(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"app":     "gitops-demo",
		"version": version,
		"pod":     env("POD_NAME", "-"),
		"node":    env("NODE_NAME", "-"),
		"uptime":  time.Since(startedAt).Round(time.Second).String(),
	})
}

// handleHealthz est la liveness : elle ne dit que « le process est vivant ».
// Elle reste à 200 pendant le drain, sinon Kubernetes tuerait le pod en plein
// arrêt propre.
func handleHealthz(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok"})
}

// handleReadyz est la readiness : elle dit « je peux recevoir du trafic ».
func handleReadyz(c *gin.Context) {
	select {
	case <-draining:
		c.JSON(http.StatusServiceUnavailable, gin.H{"status": "shutting down"})
	default:
		c.JSON(http.StatusOK, gin.H{"status": "ready"})
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envDuration(key string, fallback time.Duration) time.Duration {
	d, err := time.ParseDuration(os.Getenv(key))
	if err != nil {
		return fallback
	}
	return d
}
