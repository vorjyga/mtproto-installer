# MTProto Proxy (Fake TLS) + Traefik

Один порт **443**: по SNI трафик к домену маскировки (например `1c.ru`) уходит в MTProxy, остальное можно отдавать другим сервисам через Traefik.

- **Telemt** — современный MTProxy (Rust, distroless), поддерживает Fake TLS.
- **Traefik** — маршрутизация TCP по SNI с TLS passthrough.

## Установка на сервере (всё тянется с GitHub)

```bash
curl -sSL https://raw.githubusercontent.com/itcaat/mtproto-installer/main/install.sh | bash
```

Скрипт установит Docker (если нужно), скачает `docker-compose.yml`, конфиги Traefik и шаблон Telemt из репозитория [itcaat/mtproto-installer](https://github.com/itcaat/mtproto-installer), сгенерирует секрет, подставит домен маскировки и запустит контейнеры. В конце выведет ссылку вида `tg://proxy?server=...&port=443&secret=...` — добавьте её в Telegram (Настройки → Данные и память → Использовать прокси).

- Домен маскировки по умолчанию: `1c.ru`. Интерактивно можно ввести другой; без TTY: `FAKE_DOMAIN=sberbank.ru curl -sSL ... | bash`.
- Каталог установки по умолчанию: `./mtproxy-data`. Другой: `INSTALL_DIR=/opt/mtproxy curl -sSL ... | bash`.

## Локальный запуск (клонирование репозитория)

После `git clone https://github.com/itcaat/mtproto-installer.git && cd mtproto-installer` можно запустить `./install.sh` — скрипт по умолчанию качает файлы с того же GitHub. Либо настроить вручную и поднять без скрипта:

1. Сгенерируйте секрет: `openssl rand -hex 16`. Скопируйте `telemt.toml.example` в `telemt.toml`, подставьте секрет и при необходимости домен в `censorship.tls_domain`.
2. В `traefik/dynamic/tcp.yml` домен в `HostSNI(...)` должен совпадать с `censorship.tls_domain` в `telemt.toml`.
3. Запуск: `docker compose up -d`.
4. Ссылка: выполните `./regen-link.sh` — он сам достанет секрет и домен из `telemt.toml`, посчитает `hex(домен)` и соберёт ссылку `tg://proxy?server=...&port=443&secret=ee<секрет><hex_домена>`.

## Смена домена маскировки

Домен маскировки зашит в сам секрет ссылки (`ee` + секрет + `hex(домен)`) и отправляется клиентом как TLS SNI. Поэтому поменять только `tls_domain` в `telemt.toml` недостаточно: старые ссылки продолжат слать старый SNI, и Telemt их отклонит (`unknown_sni_action=Drop`). Домен должен совпадать сразу в трёх местах — `telemt.toml`, `traefik/dynamic/tcp.yml` и в самой ссылке.

`regen-link.sh` делает всё это сам, hex домена руками считать не нужно. Запускайте из каталога установки (по умолчанию `mtproxy-data`):

```bash
cd mtproxy-data
./regen-link.sh                # показать текущую ссылку (ничего не меняя)
./regen-link.sh newdomain.ru   # сменить домен во всех конфигах, перезапустить стек, выдать новую ссылку
./regen-link.sh --help         # справка
```

При смене домена скрипт правит `censorship.tls_domain` в `telemt.toml`, `HostSNI(...)` в `traefik/dynamic/tcp.yml`, перезапускает контейнеры (`docker compose restart`) и печатает новую ссылку `tg://proxy?server=...&port=443&secret=ee<секрет><hex_домена>`. Секрет и домен берутся из `telemt.toml` — отдельно указывать ничего не нужно.

Опции:

| Опция | Назначение |
|---|---|
| `-d, --domain <домен>` | новый домен маскировки (то же, что позиционный аргумент) |
| `--dir <путь>` | каталог установки, если запускаете не из него (по умолчанию `.` либо `./mtproxy-data`) |
| `--no-restart` | не перезапускать `docker compose` после смены домена |
| `-h, --help` | показать справку |

Переменные окружения:

| Переменная | Назначение |
|---|---|
| `FAKE_DOMAIN` | новый домен вместо аргумента: `FAKE_DOMAIN=newdomain.ru ./regen-link.sh` |
| `INSTALL_DIR` | каталог установки (аналог `--dir`) |
| `SERVER_IP` | явный IP в ссылке (по умолчанию определяется через `ifconfig.me`) |
| `LINK_PORT` | порт в ссылке (по умолчанию `443`) |

После смены домена раздайте новую ссылку всем клиентам — старая работать не будет.

## Полезные команды

- Показать / сменить ссылку: `./regen-link.sh [новый-домен]`
- Логи: `docker compose logs -f`
- Остановка: `docker compose down`
- Перезапуск после смены конфига: `docker compose up -d --force-recreate`

## Безопасность

- Ссылку прокси не публикуйте.
- Рекомендуется порт 443 и домен маскировки с рабочим HTTPS (1c.ru, sberbank.ru и т.п.).
- Регулярно обновляйте образы: `docker compose pull && docker compose up -d`.

## Структура (после install.sh)

```text
mtproxy-data/
├── docker-compose.yml
├── telemt.toml
├── regen-link.sh     # смена домена маскировки / перегенерация ссылки
└── traefik/
    ├── dynamic/
    │   └── tcp.yml    # маршрут по SNI → telemt:1234
    └── static/
```

В репозитории те же файлы приведены как примеры для ручного развёртывания.
