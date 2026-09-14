# syntax=docker/dockerfile:1

FROM golang:1.26-alpine AS build
WORKDIR /src

# Les dépendances changent beaucoup moins souvent que le code : les télécharger
# avant de copier les sources garde cette couche en cache entre deux builds.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# VERSION porte le SHA du commit, injecté dans le binaire par le linker.
# C'est ce qui permet, en démo, de voir quelle version répond dans une boucle curl.
ARG VERSION=dev
RUN CGO_ENABLED=0 go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/app .

# distroless static : ni shell, ni gestionnaire de paquets, ni libc. La surface
# d'attaque se limite au binaire, et l'image reste sous les 10 Mo.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app

# UID numérique, pas le nom « nonroot » : avec runAsNonRoot: true, la kubelet doit
# pouvoir vérifier que l'utilisateur n'est pas root *avant* de démarrer le conteneur,
# et elle ne sait pas résoudre un nom. 65532 est l'uid de nonroot chez distroless.
USER 65532:65532
EXPOSE 8080

# Forme exec, impérativement : en forme shell le binaire tournerait sous /bin/sh,
# qui ne relaierait pas le SIGTERM — l'arrêt propre ne se déclencherait jamais et
# chaque déploiement couperait des connexions.
ENTRYPOINT ["/app"]
