#!/usr/bin/env bash
# MTProto Proxy (Fake TLS) + Traefik — установка одной командой
# Все файлы загружаются с https://github.com/itcaat/mtproto-installer
# Запуск на сервере: curl -sSL https://raw.githubusercontent.com/itcaat/mtproto-installer/main/install.sh | bash

set -e

REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/itcaat/mtproto-installer/main}"
INSTALL_DIR="${INSTALL_DIR:-$(pwd)/mtproxy-data}"
FAKE_DOMAIN="${FAKE_DOMAIN:-1c.ru}"
TELEMT_INTERNAL_PORT="${TELEMT_INTERNAL_PORT:-1234}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

# --- Загрузка файла с GitHub
fetch() {
	local url="$1"
	local dest="$2"
	if ! curl -fsSL "$url" -o "$dest"; then
		err "Не удалось загрузить: $url"
	fi
}

# --- Проверка Docker
check_docker() {
	if command -v docker &>/dev/null; then
		if docker info &>/dev/null 2>&1; then
			info "Docker доступен."
			return 0
		fi
		warn "Docker установлен, но текущий пользователь не в группе docker. Запустите: sudo usermod -aG docker \$USER && newgrp docker"
		err "Или запустите этот скрипт с sudo."
	fi
	info "Установка Docker..."
	curl -fsSL https://get.docker.com | sh
	if ! docker info &>/dev/null 2>&1; then
		err "После установки Docker выполните: sudo usermod -aG docker \$USER && newgrp docker (или перелогиньтесь), затем снова запустите скрипт."
	fi
}

# --- Запрос домена маскировки
prompt_fake_domain() {
	if [[ -n "${FAKE_DOMAIN_FROM_ENV}" ]]; then
		FAKE_DOMAIN="${FAKE_DOMAIN_FROM_ENV}"
		return
	fi
	if [[ -t 0 ]]; then
		echo -n "Домен для маскировки Fake TLS [${FAKE_DOMAIN}]: "
		read -r input
		[[ -n "$input" ]] && FAKE_DOMAIN="$input"
	fi
}

# --- Генерация секрета Telemt (32 hex = 16 bytes)
generate_secret() {
	openssl rand -hex 16
}

# --- Скачать конфиги из репозитория и подставить секрет/домен
download_and_configure() {
	info "Загрузка файлов из ${REPO_RAW} ..."
	mkdir -p "${INSTALL_DIR}/traefik/dynamic" "${INSTALL_DIR}/traefik/static"

	fetch "${REPO_RAW}/docker-compose.yml" "${INSTALL_DIR}/docker-compose.yml"
	fetch "${REPO_RAW}/traefik/dynamic/tcp.yml" "${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	fetch "${REPO_RAW}/telemt.toml.example" "${INSTALL_DIR}/telemt.toml.example"

	SECRET=$(generate_secret)

	# telemt.toml: подставить секрет и домен
	sed -e "s/ПОДСТАВЬТЕ_32_СИМВОЛА_HEX/${SECRET}/g" \
	    -e "s/tls_domain = \"1c.ru\"/tls_domain = \"${FAKE_DOMAIN}\"/g" \
	    "${INSTALL_DIR}/telemt.toml.example" > "${INSTALL_DIR}/telemt.toml"
	rm -f "${INSTALL_DIR}/telemt.toml.example"
	info "Создан ${INSTALL_DIR}/telemt.toml (домен маскировки: ${FAKE_DOMAIN})"

	# traefik/dynamic/tcp.yml: подставить домен в HostSNI и порт
	local tcp_yml="${INSTALL_DIR}/traefik/dynamic/tcp.yml"
	sed -e "s/1c\.ru/${FAKE_DOMAIN}/g" \
	    -e "s/telemt:1234/telemt:${TELEMT_INTERNAL_PORT}/g" \
	    "$tcp_yml" > "${tcp_yml}.tmp" && mv "${tcp_yml}.tmp" "$tcp_yml"
	info "Настроен Traefik: SNI ${FAKE_DOMAIN} -> telemt:${TELEMT_INTERNAL_PORT} (TLS passthrough)"

	# Скрипт перегенерации ссылки / смены домена (ссылка собирается сама, без ручного hex)
	fetch "${REPO_RAW}/regen-link.sh" "${INSTALL_DIR}/regen-link.sh"
	chmod +x "${INSTALL_DIR}/regen-link.sh"
}

# --- Запуск контейнеров
run_compose() {
	cd "${INSTALL_DIR}"
	docker compose pull -q 2>/dev/null || true
	docker compose up -d
	info "Контейнеры запущены."
}

# --- Справочная информация (ссылку печатает regen-link.sh)
print_footer() {
  echo "Сохраните ссылку и не публикуйте её публично."
  echo "Данные установки: ${INSTALL_DIR}"
  echo "Логи:      cd ${INSTALL_DIR} && docker compose logs -f"
  echo "Остановка: cd ${INSTALL_DIR} && docker compose down"
  echo "Показать ссылку ещё раз:      cd ${INSTALL_DIR} && ./regen-link.sh"
  echo "Сменить домен маскировки:     cd ${INSTALL_DIR} && ./regen-link.sh newdomain.ru"
  echo "  (ссылка пересоберётся сама, стек перезапустится — раздайте новую ссылку клиентам)"
}

# --- Main
main() {
	[[ "${INSTALL_DIR}" != /* ]] && INSTALL_DIR="$(pwd)/${INSTALL_DIR}"
	check_docker
	prompt_fake_domain
	download_and_configure
	run_compose
	INSTALL_DIR="${INSTALL_DIR}" bash "${INSTALL_DIR}/regen-link.sh" --dir "${INSTALL_DIR}" --no-restart
	print_footer
}

main "$@"
