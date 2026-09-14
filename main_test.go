package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func newRouter() *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/", handleRoot)
	r.GET("/message", handleMessage)
	r.GET("/healthz", handleHealthz)
	r.GET("/readyz", handleReadyz)
	return r
}

func get(t *testing.T, path string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	newRouter().ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
	return w
}

func TestRootExposesVersion(t *testing.T) {
	w := get(t, "/")
	if w.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", w.Code)
	}

	var body map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("réponse illisible: %v", err)
	}
	if body["version"] != version {
		t.Errorf("version = %q, want %q", body["version"], version)
	}
	if body["app"] != "gitops-demo" {
		t.Errorf("app = %q, want %q", body["app"], "gitops-demo")
	}
}

func TestMessageServesTheConstant(t *testing.T) {
	w := get(t, "/message")
	if w.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", w.Code)
	}
	if got := strings.TrimSpace(w.Body.String()); got != message {
		t.Errorf("body = %q, want %q", got, message)
	}
}

func TestHealthzAlwaysOK(t *testing.T) {
	if w := get(t, "/healthz"); w.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", w.Code)
	}
}

// La readiness doit basculer en 503 dès le début du drain : c'est ce qui sort le
// pod des endpoints du Service et rend le déploiement invisible pour les clients.
func TestReadyzFailsWhileDraining(t *testing.T) {
	if w := get(t, "/readyz"); w.Code != http.StatusOK {
		t.Fatalf("avant drain: code = %d, want 200", w.Code)
	}

	close(draining)

	if w := get(t, "/readyz"); w.Code != http.StatusServiceUnavailable {
		t.Fatalf("pendant drain: code = %d, want 503", w.Code)
	}
}
