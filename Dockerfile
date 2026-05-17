# =============================================================================
# Dockerfile — P2: FHIR-FL Bridge
# Mindala Health — CNPJ 64.763.242/0001-10
#
# PARÁBOLA DO ALAMBIQUE
#
# O alambique não é o destilado — ele é o processo.
# O fogo aquece, o vapor sobe, esfria, condensa,
# e o que sai do outro lado é a essência pura.
# O alambique descarta o que não é necessário
# e guarda apenas o que importa.
#
# Este Dockerfile é o alambique: um estágio builder
# compila tudo, e o estágio runtime carrega apenas
# o binário final — sem Elixir, sem Mix, sem código-fonte.
# Apenas a aplicação destilada.
#
# — Parábola do Alambique (tradição dos produtores de cachaça de Paraty)
# =============================================================================

# =============================================================================
# Estágio 1 — Builder
# Instala deps, compila assets e gera o release OTP
# =============================================================================
FROM hexpm/elixir:1.16.3-erlang-26.2.5-alpine-3.20.0 AS builder

# Dependências de sistema para compilação
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm

WORKDIR /app

# Configura Mix para produção
ENV MIX_ENV=prod

# Copia arquivos de dependências primeiro (melhor uso do cache Docker)
COPY mix.exs mix.lock* ./
COPY config config

# Instala dependências Hex (camada cacheável)
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get --only $MIX_ENV && \
    mix deps.compile

# Copia código-fonte e compila
COPY lib lib
COPY priv priv

RUN mix compile

# Gera release OTP (binário autossuficiente)
RUN mix release

# =============================================================================
# Estágio 2 — Runtime
# Imagem mínima: apenas Alpine + runtime Erlang + o release compilado
# Resultado: ~80–120MB vs ~800MB de uma imagem Elixir completa
# =============================================================================
FROM alpine:3.20.0 AS runtime

# Runtime mínimo: libstdc++, libgcc, openssl (para Phoenix HTTPS)
RUN apk add --no-cache \
    libstdc++ \
    openssl \
    ncurses-libs \
    # Necessário para timezone awareness
    tzdata

WORKDIR /app

# Cria usuário não-root (boa prática de segurança)
RUN addgroup -g 1000 mindala && \
    adduser -u 1000 -G mindala -s /bin/sh -D mindala

# Copia apenas o release do estágio builder
COPY --from=builder --chown=mindala:mindala /app/_build/prod/rel/fhir_fl_bridge ./

USER mindala

ENV HOME=/app
ENV TZ=America/Sao_Paulo
# Porta padrão do Phoenix
EXPOSE 4001

# Healthcheck — verifica se o serviço está respondendo
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD wget -qO- http://localhost:4001/health || exit 1

# Inicia o release OTP
CMD ["bin/fhir_fl_bridge", "start"]
