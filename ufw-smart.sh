#!/usr/bin/env bash

set -Eeuo pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
NC="\033[0m"

print_ok() {
  echo -e "${GREEN}[OK]${NC} $1" >&2
}

print_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

print_err() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_info() {
  echo -e "${BLUE}[INFO]${NC} $1" >&2
}

pause() {
  echo >&2
  read -rp "Нажми Enter для продолжения..."
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_as_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    print_warn "Скрипт нужно запускать от root. Перезапускаю через sudo..."
    exec sudo bash "$0" "$@"
  fi
}

detect_pkg_manager() {
  if command_exists apt-get; then
    echo "apt"
  elif command_exists dnf; then
    echo "dnf"
  elif command_exists yum; then
    echo "yum"
  elif command_exists pacman; then
    echo "pacman"
  elif command_exists zypper; then
    echo "zypper"
  else
    echo "unknown"
  fi
}

install_ufw() {
  local pm
  pm="$(detect_pkg_manager)"

  print_info "Устанавливаю ufw через пакетный менеджер: $pm"

  case "$pm" in
    apt)
      apt-get update
      apt-get install -y ufw
      ;;
    dnf)
      dnf install -y ufw
      systemctl enable --now ufw || true
      ;;
    yum)
      yum install -y epel-release || true
      yum install -y ufw
      systemctl enable --now ufw || true
      ;;
    pacman)
      pacman -Sy --noconfirm ufw
      systemctl enable --now ufw || true
      ;;
    zypper)
      zypper --non-interactive install ufw
      systemctl enable --now ufw || true
      ;;
    *)
      print_err "Не удалось определить пакетный менеджер."
      print_err "Установи ufw вручную и запусти скрипт снова."
      exit 1
      ;;
  esac

  if command_exists ufw; then
    print_ok "ufw установлен."
  else
    print_err "ufw не установлен. Проверь систему вручную."
    exit 1
  fi
}

check_ufw_installed() {
  if ! command_exists ufw; then
    print_warn "ufw не установлен."
    read -rp "Установить ufw сейчас? [y/N]: " answer

    case "${answer,,}" in
      y|yes|д|да)
        install_ufw
        ;;
      *)
        print_err "Без ufw скрипт продолжить не может."
        exit 1
        ;;
    esac
  else
    print_ok "ufw уже установлен."
  fi
}

get_ssh_client_ip() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "$SSH_CONNECTION" | awk '{print $1}'
  elif [[ -n "${SUDO_CLIENT:-}" ]]; then
    echo "$SUDO_CLIENT" | awk '{print $1}'
  else
    echo ""
  fi
}

get_ssh_server_port() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    echo "$SSH_CONNECTION" | awk '{print $4}'
    return
  fi

  if command_exists sshd; then
    local p
    p="$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')"
    if [[ -n "$p" ]]; then
      echo "$p"
      return
    fi
  fi

  if [[ -f /etc/ssh/sshd_config ]]; then
    local p
    p="$(grep -Ei '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | tail -n1 | awk '{print $2}' || true)"
    if [[ -n "$p" ]]; then
      echo "$p"
      return
    fi
  fi

  echo "22"
}

get_ufw_status_word() {
  ufw status | awk 'NR==1 {print tolower($2)}'
}

is_valid_ip_or_cidr() {
  local item="$1"

  if command_exists python3; then
    python3 - "$item" >/dev/null 2>&1 <<'PY'
import sys
import ipaddress

value = sys.argv[1]

try:
    ipaddress.ip_network(value, strict=False)
    sys.exit(0)
except ValueError:
    sys.exit(1)
PY
  else
    [[ "$item" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]
  fi
}

ip_in_list() {
  local client_ip="$1"
  shift
  local ip_list=("$@")

  if [[ -z "$client_ip" ]]; then
    return 1
  fi

  if ! command_exists python3; then
    local item
    for item in "${ip_list[@]}"; do
      [[ "$client_ip" == "$item" ]] && return 0
    done
    return 1
  fi

  python3 - "$client_ip" "${ip_list[@]}" >/dev/null 2>&1 <<'PY'
import sys
import ipaddress

client = ipaddress.ip_address(sys.argv[1])
networks = sys.argv[2:]

for net in networks:
    try:
        if client in ipaddress.ip_network(net, strict=False):
            sys.exit(0)
    except ValueError:
        pass

sys.exit(1)
PY
}

parse_ip_list() {
  local raw="$1"
  local cleaned
  local item
  local result=()

  cleaned="$(echo "$raw" | tr ',' ' ')"

  for item in $cleaned; do
    item="$(echo "$item" | xargs)"

    [[ -z "$item" ]] && continue

    if is_valid_ip_or_cidr "$item"; then
      result+=("$item")
    else
      print_warn "Пропускаю некорректный IP/CIDR: $item"
    fi
  done

  if [[ "${#result[@]}" -eq 0 ]]; then
    print_err "Не указано ни одного корректного IP/CIDR."
    return 1
  fi

  printf '%s\n' "${result[@]}"
}

validate_port() {
  local port="$1"

  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
    return 1
  fi

  return 0
}

ensure_ufw_enabled_safely() {
  local status
  local ssh_port
  local client_ip
  local answer

  status="$(get_ufw_status_word || true)"
  ssh_port="$(get_ssh_server_port)"
  client_ip="$(get_ssh_client_ip)"

  if [[ "$status" == "inactive" || -z "$status" ]]; then
    print_warn "ufw сейчас выключен."

    if [[ -n "$client_ip" ]]; then
      print_warn "Ты подключен по SSH с IP: $client_ip"
      print_warn "Текущий SSH-порт определён как: $ssh_port"
      echo >&2
      read -rp "Перед включением ufw разрешить SSH только с твоего текущего IP? [Y/n]: " answer

      case "${answer,,}" in
        n|no|н|нет)
          print_warn "SSH не будет добавлен автоматически."
          ;;
        *)
          ufw allow from "$client_ip" to any port "$ssh_port" proto tcp comment "SAFE SSH from current IP"
          print_ok "Добавлено безопасное SSH-правило: $client_ip -> tcp/$ssh_port"
          ;;
      esac
    else
      print_warn "Не удалось определить твой SSH IP."
      print_warn "Если ты на удалённом сервере, сначала убедись, что SSH-порт открыт."
      read -rp "Разрешить SSH tcp/$ssh_port для Anywhere перед включением ufw? [Y/n]: " answer

      case "${answer,,}" in
        n|no|н|нет)
          ;;
        *)
          ufw allow "$ssh_port/tcp" comment "SAFE SSH Anywhere"
          print_ok "Добавлено SSH-правило: Anywhere -> tcp/$ssh_port"
          ;;
      esac
    fi

    echo >&2
    print_info "Рекомендуемая базовая политика: deny incoming, allow outgoing."
    read -rp "Применить базовую политику и включить ufw? [Y/n]: " answer

    case "${answer,,}" in
      n|no|н|нет)
        print_warn "ufw оставлен выключенным. Правила можно добавлять, но они не будут активны до включения ufw."
        ;;
      *)
        ufw default deny incoming
        ufw default allow outgoing
        ufw --force enable
        print_ok "ufw включен."
        ;;
    esac
  else
    print_ok "ufw уже активен."
  fi
}

show_rules() {
  echo >&2
  print_info "Текущие правила ufw:"
  echo >&2
  ufw status numbered verbose
}

ask_protocol() {
  local default_proto="${1:-tcp}"
  local choice

  echo >&2
  echo "Выбери протокол:" >&2
  echo "1) TCP" >&2
  echo "2) UDP" >&2
  echo "3) TCP + UDP" >&2
  read -rp "Выбор [по умолчанию: $default_proto]: " choice

  case "$choice" in
    1) echo "tcp" ;;
    2) echo "udp" ;;
    3) echo "both" ;;
    "")
      echo "$default_proto"
      ;;
    *)
      print_warn "Некорректный выбор. Использую $default_proto."
      echo "$default_proto"
      ;;
  esac
}

ask_scope() {
  local choice

  echo >&2
  echo "Выбери доступ:" >&2
  echo "1) Anywhere" >&2
  echo "2) Только конкретные IP/CIDR" >&2
  read -rp "Выбор [1]: " choice

  case "$choice" in
    2) echo "acl" ;;
    *) echo "anywhere" ;;
  esac
}

ask_ip_list() {
  local raw
  local parsed

  echo >&2
  echo "Можно указать один IP, несколько IP через запятую или пробел, либо CIDR." >&2
  echo "Пример:" >&2
  echo "  1.2.3.4" >&2
  echo "  1.2.3.4, 5.6.7.8" >&2
  echo "  192.168.1.0/24 10.10.10.10" >&2
  echo >&2
  read -rp "IP/CIDR: " raw

  parsed="$(parse_ip_list "$raw")" || return 1
  echo "$parsed"
}

ask_custom_port() {
  local port

  echo >&2
  read -rp "Введи порт от 1 до 65535: " port

  if ! validate_port "$port"; then
    print_err "Некорректный порт: $port"
    return 1
  fi

  echo "$port"
}

confirm_ssh_acl_safety() {
  local port="$1"
  shift
  local ip_list=("$@")
  local ssh_port
  local client_ip
  local answer
  local confirm

  ssh_port="$(get_ssh_server_port)"
  client_ip="$(get_ssh_client_ip)"

  if [[ "$port" != "$ssh_port" && "$port" != "22" ]]; then
    return 0
  fi

  if [[ -z "$client_ip" ]]; then
    print_warn "Не удалось определить твой текущий SSH IP."
    print_warn "Если добавить ACL без твоего IP, можно потерять SSH-доступ."
    read -rp "Продолжить? Напиши YES: " confirm
    [[ "$confirm" == "YES" ]]
    return
  fi

  if ip_in_list "$client_ip" "${ip_list[@]}"; then
    return 0
  fi

  echo >&2
  print_warn "ВНИМАНИЕ: ты подключен по SSH с IP: $client_ip"
  print_warn "Но этот IP не входит в список ACL."
  print_warn "Если удалить Anywhere или закрыть SSH, можно потерять доступ."

  read -rp "Добавить текущий IP $client_ip в ACL автоматически? [Y/n]: " answer

  case "${answer,,}" in
    n|no|н|нет)
      read -rp "Продолжить без текущего IP? Напиши YES: " confirm
      [[ "$confirm" == "YES" ]]
      ;;
    *)
      echo "$client_ip"
      return 2
      ;;
  esac
}

apply_allow_rule() {
  local port="$1"
  local proto="$2"
  local scope="$3"
  local comment="$4"
  shift 4
  local ip_list=("$@")
  local p
  local ip

  if ! validate_port "$port"; then
    print_err "Некорректный порт: $port"
    return 1
  fi

  if [[ "$proto" == "both" ]]; then
    for p in tcp udp; do
      apply_allow_rule "$port" "$p" "$scope" "$comment" "${ip_list[@]}"
    done
    return
  fi

  if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
    print_err "Некорректный протокол: $proto"
    return 1
  fi

  if [[ "$scope" == "anywhere" ]]; then
    ufw allow "$port/$proto" comment "$comment"
    print_ok "Открыто: Anywhere -> $proto/$port"
  elif [[ "$scope" == "acl" ]]; then
    if [[ "${#ip_list[@]}" -eq 0 ]]; then
      print_err "Для ACL не передан список IP."
      return 1
    fi

    for ip in "${ip_list[@]}"; do
      ufw allow from "$ip" to any port "$port" proto "$proto" comment "$comment"
      print_ok "Открыто: $ip -> $proto/$port"
    done
  else
    print_err "Некорректный scope: $scope"
    return 1
  fi
}

open_port_interactive() {
  local service_name="$1"
  local port="$2"
  local forced_proto="${3:-}"
  local proto
  local scope
  local ip_lines
  local ip_list=()
  local extra_ip=""
  local rc

  echo >&2
  print_info "Настройка правила: $service_name, порт $port"

  if [[ "$forced_proto" == "both" ]]; then
    proto="both"
    print_info "Для этого пункта будет открыт TCP + UDP."
  elif [[ "$forced_proto" == "tcp" || "$forced_proto" == "udp" ]]; then
    proto="$forced_proto"
    print_info "Для этого пункта будет открыт протокол: $proto"
  else
    proto="$(ask_protocol "tcp")"
  fi

  scope="$(ask_scope)"

  if [[ "$scope" == "acl" ]]; then
    ip_lines="$(ask_ip_list)" || return
    mapfile -t ip_list <<< "$ip_lines"

    if [[ "$service_name" == "SSH" || "$port" == "$(get_ssh_server_port)" || "$port" == "22" ]]; then
      set +e
      extra_ip="$(confirm_ssh_acl_safety "$port" "${ip_list[@]}")"
      rc=$?
      set -e

      if [[ "$rc" -eq 2 && -n "$extra_ip" ]]; then
        ip_list+=("$extra_ip")
        print_ok "Текущий SSH IP добавлен в ACL: $extra_ip"
      elif [[ "$rc" -ne 0 ]]; then
        print_err "Операция отменена для защиты SSH-доступа."
        return
      fi
    fi
  fi

  apply_allow_rule "$port" "$proto" "$scope" "SMART UFW: $service_name" "${ip_list[@]}"
  reload_ufw
}

open_custom_port() {
  local port

  port="$(ask_custom_port)" || return
  open_port_interactive "Custom port $port" "$port"
}

delete_rule_by_number() {
  local num
  local rule_line
  local ssh_port
  local confirm

  show_rules

  echo >&2
  read -rp "Введи номер правила для удаления: " num

  if ! [[ "$num" =~ ^[0-9]+$ ]]; then
    print_err "Нужно ввести номер правила."
    return
  fi

  rule_line="$(ufw status numbered | sed -n "s/^\[[[:space:]]*$num\][[:space:]]*//p" || true)"
  ssh_port="$(get_ssh_server_port)"

  if [[ -z "$rule_line" ]]; then
    print_err "Правило с номером $num не найдено."
    return
  fi

  echo >&2
  print_info "Выбрано правило:"
  echo "$rule_line" >&2
  echo >&2

  if echo "$rule_line" | grep -Eiq "(OpenSSH|SSH|(^|[^0-9])22(/tcp|/udp|[^0-9]|$)|(^|[^0-9])${ssh_port}(/tcp|/udp|[^0-9]|$))"; then
    print_warn "Это похоже на SSH-правило."
    print_warn "Удаление может оборвать доступ к серверу."
    read -rp "Для подтверждения удаления SSH-правила напиши DELETE-SSH: " confirm

    if [[ "$confirm" != "DELETE-SSH" ]]; then
      print_err "Удаление отменено."
      return
    fi
  else
    read -rp "Удалить это правило? [y/N]: " confirm

    case "${confirm,,}" in
      y|yes|д|да)
        ;;
      *)
        print_warn "Удаление отменено."
        return
        ;;
    esac
  fi

  ufw --force delete "$num"
  print_ok "Правило удалено."
  reload_ufw
}

delete_anywhere_rules_for_port_proto() {
  local port="$1"
  local proto="$2"
  local numbers=()
  local line
  local num
  local confirm
  local idx

  while IFS= read -r line; do
    if echo "$line" | grep -Eq "^\[[[:space:]]*[0-9]+\]" &&
       echo "$line" | grep -Eq "${port}/${proto}" &&
       echo "$line" | grep -Eq "ALLOW IN" &&
       echo "$line" | grep -Eq "Anywhere"; then

      num="$(echo "$line" | sed -E 's/^\[[[:space:]]*([0-9]+)\].*/\1/')"
      numbers+=("$num")
    fi
  done < <(ufw status numbered)

  if [[ "${#numbers[@]}" -eq 0 ]]; then
    print_info "Anywhere-правил для $proto/$port не найдено."
    return
  fi

  print_warn "Будут удалены Anywhere-правила для $proto/$port: ${numbers[*]}"
  read -rp "Удалить эти Anywhere-правила? [y/N]: " confirm

  case "${confirm,,}" in
    y|yes|д|да)
      ;;
    *)
      print_warn "Удаление Anywhere-правил отменено."
      return
      ;;
  esac

  for (( idx=${#numbers[@]}-1 ; idx>=0 ; idx-- )); do
    ufw --force delete "${numbers[$idx]}"
  done

  print_ok "Anywhere-правила удалены."
}

restrict_existing_port_with_acl() {
  local port
  local proto
  local ip_lines
  local ip_list=()
  local extra_ip=""
  local delete_anywhere
  local rc

  show_rules

  echo >&2
  read -rp "Введи порт, к которому нужно добавить ACL: " port

  if ! validate_port "$port"; then
    print_err "Некорректный порт."
    return
  fi

  proto="$(ask_protocol "tcp")"

  ip_lines="$(ask_ip_list)" || return
  mapfile -t ip_list <<< "$ip_lines"

  if [[ "$port" == "$(get_ssh_server_port)" || "$port" == "22" ]]; then
    set +e
    extra_ip="$(confirm_ssh_acl_safety "$port" "${ip_list[@]}")"
    rc=$?
    set -e

    if [[ "$rc" -eq 2 && -n "$extra_ip" ]]; then
      ip_list+=("$extra_ip")
      print_ok "Текущий SSH IP добавлен в ACL: $extra_ip"
    elif [[ "$rc" -ne 0 ]]; then
      print_err "Операция отменена для защиты SSH-доступа."
      return
    fi
  fi

  apply_allow_rule "$port" "$proto" "acl" "SMART UFW ACL for port $port" "${ip_list[@]}"

  echo >&2
  print_warn "ACL добавлен. Но если раньше был открыт Anywhere, он останется, пока его не удалить."
  read -rp "Удалить Anywhere-правила для этого порта/протокола? [y/N]: " delete_anywhere

  case "${delete_anywhere,,}" in
    y|yes|д|да)
      if [[ "$proto" == "both" ]]; then
        delete_anywhere_rules_for_port_proto "$port" "tcp"
        delete_anywhere_rules_for_port_proto "$port" "udp"
      else
        delete_anywhere_rules_for_port_proto "$port" "$proto"
      fi
      ;;
    *)
      print_warn "Anywhere-правила не удалялись."
      ;;
  esac

  reload_ufw
}

reload_ufw() {
  echo >&2
  print_info "Перезагружаю правила ufw..."

  if ufw reload; then
    print_ok "Правила ufw загружены."
    return
  fi

  print_warn "ufw reload не сработал. Пробую ufw --force enable..."
  ufw --force enable
  print_ok "ufw включен и правила загружены."
}

main_menu() {
  local ssh_port
  local choice

  while true; do
    ssh_port="$(get_ssh_server_port)"

    clear
    echo "============================================"
    echo " SMART UFW MANAGER"
    echo "============================================"
    echo
    echo "Текущий SSH-порт определен как: $ssh_port"
    echo
    echo "Основные действия:"
    echo "1) Открыть SSH"
    echo "2) Открыть 443"
    echo "3) Открыть 80"
    echo "4) Открыть 2053"
    echo "5) Открыть 500 TCP + UDP"
    echo "6) Открыть свой порт"
    echo
    echo "Управление правилами:"
    echo "7) Показать текущие правила"
    echo "8) Удалить правило по номеру"
    echo "9) Добавить ACL к существующему порту"
    echo "10) Перезагрузить ufw rules"
    echo "0) Выход"
    echo
    read -rp "Выбор: " choice

    case "$choice" in
      1)
        open_port_interactive "SSH" "$ssh_port" "tcp"
        pause
        ;;
      2)
        open_port_interactive "HTTPS 443" "443"
        pause
        ;;
      3)
        open_port_interactive "HTTP 80" "80"
        pause
        ;;
      4)
        open_port_interactive "Port 2053" "2053"
        pause
        ;;
      5)
        open_port_interactive "Port 500" "500" "both"
        pause
        ;;
      6)
        open_custom_port
        pause
        ;;
      7)
        show_rules
        pause
        ;;
      8)
        delete_rule_by_number
        pause
        ;;
      9)
        restrict_existing_port_with_acl
        pause
        ;;
      10)
        reload_ufw
        show_rules
        pause
        ;;
      0)
        reload_ufw
        echo
        print_ok "Готово."
        exit 0
        ;;
      *)
        print_warn "Некорректный выбор."
        pause
        ;;
    esac
  done
}

main() {
  run_as_root "$@"
  check_ufw_installed
  ensure_ufw_enabled_safely
  main_menu
}

main "$@"
