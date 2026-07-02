#!/usr/bin/env bash
# Перегенерация ссылки Telegram и (опционально) смена домена маскировки Fake TLS.
#
# Домен маскировки зашит в сам секрет ссылки (ee + <секрет> + hex(домен)) и
# отправляется клиентом как TLS SNI. Поэтому при смене домена нужно менять его
# сразу в трёх местах и заново раздавать ссылку:
#   1) telemt.toml            -> censorship.tls_domain
#   2) traefik/dynamic/tcp.yml -> HostSNI(`...`)
#   3) ссылка у клиентов       -> hex(домена)
# Этот скрипт делает всё это сам — руками hex считать не нужно.
#
# Использование:
#   ./regen-link.sh                 показать текущую ссылку (ничего не меняя)
#   ./regen-link.sh newdomain.ru    сменить домен во всех конфигах, перезапустить, показать ссылку
#   FAKE_DOMAIN=newdomain.ru ./regen-link.sh
#
# Опции:
#   -d, --domain <домен>   новый домен маскировки
#   --dir <путь>           каталог установки (где лежит telemt.toml); по умолчанию автоопределение
#   --no-restart           не перезапускать docker compose после смены домена
#   -h, --help             показать эту справку

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-}"
NEW_DOMAIN="${FAKE_DOMAIN:-}"
DO_RESTART=1

# --- разбор аргументов
while [[ $# -gt 0 ]]; do
	case "$1" in
		-d|--domain) NEW_DOMAIN="$2"; shift 2 ;;
		--dir)       INSTALL_DIR="$2"; shift 2 ;;
		--no-restart) DO_RESTART=0; shift ;;
		-h|--help)   sed -n 's/^# \{0,1\}//p' "$0"; exit 0 ;;
		-*)          err "Неизвестная опция: $1" ;;
		*)           NEW_DOMAIN="$1"; shift ;;
	esac
done

# --- автоопределение каталога установки
if [[ -z "$INSTALL_DIR" ]]; then
	if   [[ -f "./telemt.toml" ]];               then INSTALL_DIR="."
	elif [[ -f "./mtproxy-data/telemt.toml" ]];  then INSTALL_DIR="./mtproxy-data"
	else err "Не найден telemt.toml. Укажите каталог: --dir <путь>"
	fi
fi
TOML="${INSTALL_DIR}/telemt.toml"
TCP_YML="${INSTALL_DIR}/traefik/dynamic/tcp.yml"
[[ -f "$TOML" ]] || err "Не найден ${TOML}"

# --- hex строки без зависимости от xxd (fallback на od)
to_hex() {
	if command -v xxd >/dev/null 2>&1; then
		printf '%s' "$1" | xxd -p -c 256 | tr -d '\n'
	else
		printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
	fi
}

# --- секрет (32 hex) из telemt.toml [access.users]; fallback .secret
get_secret() {
	local s
	s=$(sed -n '/^[[:space:]]*\[access\.users\]/,/^[[:space:]]*\[/p' "$TOML" \
		| grep -oiE '[0-9a-f]{32}' | head -n1)
	if [[ -z "$s" && -f "${INSTALL_DIR}/.secret" ]]; then
		s=$(tr -dc '0-9a-fA-F' < "${INSTALL_DIR}/.secret")
	fi
	printf '%s' "$s"
}

# --- текущий tls_domain из telemt.toml
get_domain() {
	grep -E '^[[:space:]]*tls_domain[[:space:]]*=' "$TOML" \
		| head -n1 | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/'
}

# --- сменить домен в telemt.toml и tcp.yml
set_domain() {
	local d="$1" bt='`'
	sed -E -i.bak "s|^([[:space:]]*tls_domain[[:space:]]*=[[:space:]]*).*|\\1\"${d}\"|" "$TOML"
	rm -f "${TOML}.bak"
	if [[ -f "$TCP_YML" ]]; then
		sed -E -i.bak "s|HostSNI\\(${bt}[^${bt}]*${bt}\\)|HostSNI(${bt}${d}${bt})|" "$TCP_YML"
		rm -f "${TCP_YML}.bak"
	else
		warn "Не найден ${TCP_YML} — пропускаю обновление Traefik HostSNI."
	fi
}

# --- перезапуск стека
restart_stack() {
	if ! command -v docker >/dev/null 2>&1; then
		warn "docker не найден — перезапустите стек вручную: cd ${INSTALL_DIR} && docker compose restart"
		return
	fi
	if ( cd "$INSTALL_DIR" && docker compose restart ); then
		info "Стек перезапущен."
	else
		warn "Не удалось перезапустить docker compose — сделайте это вручную: cd ${INSTALL_DIR} && docker compose restart"
	fi
}

# === основной сценарий ===

# смена домена (если задан)
if [[ -n "$NEW_DOMAIN" ]]; then
	[[ "$NEW_DOMAIN" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
		|| err "Домен выглядит некорректно: ${NEW_DOMAIN}"
	OLD_DOMAIN=$(get_domain)
	set_domain "$NEW_DOMAIN"
	info "Домен маскировки: ${OLD_DOMAIN:-?} -> ${NEW_DOMAIN} (telemt.toml + Traefik HostSNI)"
	[[ "$DO_RESTART" -eq 1 ]] && restart_stack
	warn "Старые ссылки со старым доменом больше не работают — раздайте новую ссылку всем клиентам."
fi

# сборка ссылки
SECRET=$(get_secret)
[[ -n "$SECRET" ]] || err "Не удалось извлечь секрет из ${TOML} (секция [access.users])."
TLS_DOMAIN=$(get_domain)
[[ -n "$TLS_DOMAIN" ]] || err "Не удалось извлечь tls_domain из ${TOML}."

DOMAIN_HEX=$(to_hex "$TLS_DOMAIN")
if [[ "$SECRET" =~ ^[0-9a-fA-F]{32}$ ]]; then
	LONG_SECRET="ee${SECRET}${DOMAIN_HEX}"      # ee + секрет + hex(домен)
else
	LONG_SECRET="$SECRET"                        # уже длинный/нестандартный — как есть
fi

SERVER_IP="${SERVER_IP:-$(curl -s --connect-timeout 3 ifconfig.me 2>/dev/null || echo "YOUR_SERVER_IP")}"
LINK_PORT="${LINK_PORT:-443}"
LINK="tg://proxy?server=${SERVER_IP}&port=${LINK_PORT}&secret=${LONG_SECRET}"

echo ""
echo -e "${GREEN}--- Ссылка для Telegram (домен маскировки: ${TLS_DOMAIN}) ---${NC}"
echo "${LINK}"
echo ""
