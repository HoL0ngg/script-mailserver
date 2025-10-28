
#!/bin/bash
#Các packages cần cài đặt
readonly PACKAGES=("bind" "bind-utils" "dovecot" "postfix" "epel-release" "squirrelmail")
readonly EXTERNAL_LINK_EPEL_RELEASE="https://dl.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/e/epel-release-7-14.noarch.rpm"

pause() {
	read -p "Nhấn Enter để quay lại menu..."
}

pause2() {
	read -p "Nhấn Enter để tiếp tục..."
}
check_network_connection() {
	ping -c 1 8.8.8.8 &> /dev/null
}

# Colors for output
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
NC="\e[0m"

# Configuration paths
NAMED_CONF="/etc/named.conf"
NAMED_ZONES="/etc/named.rfc1912.zones"
ZONE_DIR="/var/named"
BACKUP_DIR="/var/backup/dns"
GROUP="named"

# ========== Logging helpers ==========
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${CYAN}[SUCCESS]${NC} $1"; }

# ========== Validate ==========
validate_ip() {
  local ip=$1
  local stat=1

  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a octets <<< "$ip"
    if [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]; then
      stat=0
    fi
  fi
  return $stat
}

configure_ip_and_named() {
    log "Cấu hình IP tĩnh và tạo named.conf..."

    # Cài ipcalc nếu chưa có
    if ! command -v ipcalc >/dev/null 2>&1; then
        log "ipcalc chưa cài, đang cài đặt..."
        sudo yum install ipcalc -y >/dev/null 2>&1
        log "ipcalc đã cài xong."
    fi

    # Xác định interface và connection
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    INTERFACE=${INTERFACE:-ens33}
    # log "Interface hiện tại: $INTERFACE"

#   CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | grep "$INTERFACE" | cut -d: -f1)
    CON_NAME=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v ifc="${INTERFACE}" '$2==ifc {print $1; exit}')

    if [ -z "$CON_NAME" ]; then
        log "Không tìm thấy connection cho interface $INTERFACE"
        return 1
    fi
    # log "Connection hiện tại: $CON_NAME"

    # Nhập thông tin IP tĩnh
    read -p "Nhập địa chỉ IP tĩnh (mặc định: 192.168.1.1): " IP_ADDR
    IP_ADDR=${IP_ADDR:-192.168.1.1}

    read -p "Nhập Subnet Mask (mặc định: 255.255.255.0): " NETMASK
    NETMASK=${NETMASK:-255.255.255.0}

    read -p "Nhập Gateway (mặc định: 192.168.1.1): " GATEWAY
    GATEWAY=${GATEWAY:-192.168.1.1}

    PREFIX=$(ipcalc -p $IP_ADDR $NETMASK | cut -d= -f2)
    NETWORK=$(ipcalc -n $IP_ADDR $NETMASK | cut -d= -f2)

    # Áp dụng IP tĩnh
    sudo nmcli con mod "$CON_NAME" ipv4.addresses "$IP_ADDR/$PREFIX"
    sudo nmcli con mod "$CON_NAME" ipv4.gateway "$GATEWAY"
    sudo nmcli con mod "$CON_NAME" ipv4.dns "$IP_ADDR"
    sudo nmcli con mod "$CON_NAME" ipv4.method manual
    sudo nmcli con up "$CON_NAME"
    log "IP tĩnh đã được áp dụng: $IP_ADDR/$PREFIX, Gateway: $GATEWAY"

    # Tạo named.conf
    log "Tạo file /etc/named.conf ..."
    sudo tee /etc/named.conf > /dev/null <<EOF
options {
    directory "/var/named";
    listen-on port 53 { 127.0.0.1; $IP_ADDR; };
    allow-query { 127.0.0.1; $NETWORK/$PREFIX; any; };
    recursion yes;
    dnssec-enable no;
    dnssec-validation no;
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

zone "." IN {
    type hint;
    file "named.ca";
};

include "/etc/named.rfc1912.zones";
include "/etc/named.root.key";
EOF

    sudo chown root:named /etc/named.conf
    sudo chmod 644 /etc/named.conf
    log "named.conf đã được tạo xong với listen-on: 127.0.0.1, $IP_ADDR và allow-query: $NETWORK/$PREFIX"
}


setup_dns_server() {
	log "Setup DNS server"
	
	firewall-cmd --permanent --zone=public --add-service=dns > /dev/null 2>&1
	firewall-cmd --reload > /dev/null 2>&1
		
	configure_ip_and_named
	
	# Start and enable named service
	sudo systemctl enable named
	sudo systemctl start named
	
	success "Cài đặt DNS server hoàn tất! Bạn có thể tiến hành tạo zone."
  echo
}

# ========== Zone & Record ==========
create_forward_zone() {
  echo "=== Tạo Forward Zone mới ==="
  while true; do
    read -p "Nhập domain (VD: example.com): " DOMAIN
    [ -z "$DOMAIN" ] && echo "Domain không được rỗng." && continue
    if ! validate_domain "${DOMAIN}"; then
	    echo "[ERROR] DOMAIN không hợp lệ!"
	    echo "[INFO]  DOMAIN phải theo định dạng (VD: example.com)."
	continue;
    fi

    if grep -q "zone \"$DOMAIN\"" "$NAMED_ZONES"; then
      echo "Zone $DOMAIN đã tồn tại, vui lòng nhập domain khác."
    else
      break
    fi
  done

  read -p "Nhập IP cho server.${DOMAIN}: " NS_IP
  while ! validate_ip "$NS_IP"; do
    error "IP không hợp lệ, vui lòng nhập lại!"
    read -p "Nhập IP cho server.${DOMAIN}: " NS_IP
  done

  FORWARD_ZONE_FILE="$ZONE_DIR/forward.${DOMAIN}"

  SERIAL=$(date +%Y%m%d)01
  cat <<EOF >"$FORWARD_ZONE_FILE"
\$TTL 86400
@   IN  SOA server.$DOMAIN. admin.$DOMAIN. (
        $SERIAL ; Serial
        3600    ; Refresh
        1800    ; Retry
        1209600 ; Expire
        86400 ) ; Minimum TTL

    IN  NS  server.$DOMAIN.
server IN  A   $NS_IP
@   IN  A   $NS_IP
EOF

  cat <<EOF >>"$NAMED_ZONES"

zone "$DOMAIN" IN {
    type master;
    file "$FORWARD_ZONE_FILE";
};
EOF
  create_reverse_zone_if_needed "${NS_IP}" "${DOMAIN}" "server"
  create_reverse_zone_if_needed "${NS_IP}" "${DOMAIN}" ""
  chown root:$GROUP "$FORWARD_ZONE_FILE"
  chmod 640 "$FORWARD_ZONE_FILE"

  systemctl restart named
  success "Zone $DOMAIN đã được tạo và dịch vụ named đã restart."
}

create_reverse_zone_if_needed() {
  local IP=$1
  local DOMAIN=$2
  local HOST=$3

  IFS='.' read -r o1 o2 o3 o4 <<< "$IP"
  local REV_ZONE="${o3}.${o2}.${o1}.in-addr.arpa"
  local REV_FILE="$ZONE_DIR/reverse.${o3}.${o2}.${o1}.in-addr.arpa"

  if [ ! -f REV_FILE ]; then
	touch "${REV_FILE}"
  fi
  # Nếu reverse zone chưa tồn tại thì tạo
  if ! grep -q "zone \"$REV_ZONE\"" "$NAMED_ZONES"; then
    SERIAL=$(date +%Y%m%d)01
    cat <<EOF > "$REV_FILE"
\$TTL 86400
@   IN  SOA server.$DOMAIN. admin.$DOMAIN. (
        $SERIAL ; Serial
        3600    ; Refresh
        1800    ; Retry
        1209600 ; Expire
        86400 ) ; Minimum TTL

    IN  NS  server.$DOMAIN.
EOF

    # Thêm vào named.rfc1912.zones
    cat <<EOF >> "$NAMED_ZONES"

zone "$REV_ZONE" IN {
    type master;
    file "$REV_FILE";
};
EOF

    chown root:$GROUP "$REV_FILE"
    chmod 640 "$REV_FILE"
    success "Reverse zone $REV_ZONE đã được tạo."
  fi

  # Thêm PTR record
  local PTR_NAME="${HOST:+${HOST}.}${DOMAIN}"
  # Kiểm tra xem PTR đã tồn tại chưa
  if ! grep -qE "^[[:space:]]*$o4[[:space:]]+IN[[:space:]]+PTR[[:space:]]+$PTR_NAME\." "$REV_FILE"; then
      echo "$o4   IN PTR $PTR_NAME." >> "$REV_FILE"
      success "PTR record $IP → $PTR_NAME đã được thêm."
  fi

  # Reload reverse zone
  rndc reload $REV_ZONE &>/dev/null || rndc reload &> /dev/null
}


add_dns_record() {
  echo "=== Thêm DNS Record ==="

  FORWARD_ZONES=()
  while IFS= read -r line; do
      if [[ $line =~ zone\ \"([^\"]+)\" ]]; then
          ZONE_NAME="${BASH_REMATCH[1]}"
          if [[ $ZONE_NAME != *"in-addr.arpa" ]]; then
              FORWARD_ZONES+=("$ZONE_NAME")
          fi
      fi
  done < "$NAMED_ZONES"

  if [ ${#FORWARD_ZONES[@]} -eq 0 ]; then
      echo " Không có Forward Zone nào."
      pause
      return
  fi

  echo "Danh sách Forward Zones:"
  for i in "${!FORWARD_ZONES[@]}"; do
      echo "  $((i+1)). ${FORWARD_ZONES[$i]}"
  done

  echo
  read -p "Chọn số thứ tự Zone để thêm record: " ZONE_INDEX
  if ! [[ $ZONE_INDEX =~ ^[0-9]+$ ]] || [ "$ZONE_INDEX" -lt 1 ] || [ "$ZONE_INDEX" -gt ${#FORWARD_ZONES[@]} ]; then
      error "Lựa chọn không hợp lệ!"
      pause
      return
  fi

  DOMAIN="${FORWARD_ZONES[$((ZONE_INDEX-1))]}"
  FORWARD_ZONE_FILE="$ZONE_DIR/forward.${DOMAIN}"

  echo "Bạn đang thêm record cho zone: $DOMAIN"
  read -p "Nhập hostname (VD: www, để trống = domain chính): " HOST
  read -p "Nhập IP cho ${HOST:+$HOST.}$DOMAIN: " IP
  while ! validate_ip "$IP"; do
    error "IP không hợp lệ, vui lòng nhập lại!"
    read -p "Nhập IP cho ${HOST:+$HOST.}$DOMAIN: " IP
  done

  # Thêm record A vào forward zone
  if [ -z "$HOST" ]; then
      echo "@   IN  A   $IP" >> "$FORWARD_ZONE_FILE"
      echo " Đã thêm record: $DOMAIN → $IP"
  else
      echo "${HOST}   IN  A   $IP" >> "$FORWARD_ZONE_FILE"
      echo " Đã thêm record: ${HOST}.${DOMAIN} → $IP"
  fi

  # Kiểm tra & gợi ý tạo reverse zone
  create_reverse_zone_if_needed "$IP" "$DOMAIN" "$HOST"
# Reload forward zone luôn
  rndc reload $DOMAIN &> /dev/null



  pause
}


list_zones() {
    clear
    echo "=== Danh sách Zones ==="

    FORWARD_ZONES=()
    REVERSE_ZONES=()

    while IFS= read -r line; do
        if [[ $line =~ zone\ \"([^\"]+)\" ]]; then
            ZONE_NAME="${BASH_REMATCH[1]}"
            if [[ $ZONE_NAME == *"in-addr.arpa" ]]; then
                REVERSE_ZONES+=("$ZONE_NAME")
            else
                FORWARD_ZONES+=("$ZONE_NAME")
            fi
        fi
    done < "$NAMED_ZONES"

    echo "Forward Zones:"
    if [ ${#FORWARD_ZONES[@]} -eq 0 ]; then
        echo "  (Không có Forward Zone nào)"
    else
        for z in "${FORWARD_ZONES[@]}"; do
            echo "  - $z"
        done
    fi

    echo
    echo "Reverse Zones:"
    if [ ${#REVERSE_ZONES[@]} -eq 0 ]; then
        echo "  (Không có Reverse Zone nào)"
    else
        for z in "${REVERSE_ZONES[@]}"; do
            echo "  - $z"
        done
    fi

    echo
}

list_records() {
  echo "=== Xem records của Zone ==="

  FORWARD_ZONES=()
  while IFS= read -r line; do
      if [[ $line =~ zone\ \"([^\"]+)\" ]]; then
          ZONE_NAME="${BASH_REMATCH[1]}"
          if [[ $ZONE_NAME != *"in-addr.arpa" ]]; then
              FORWARD_ZONES+=("$ZONE_NAME")
          fi
      fi
  done < "$NAMED_ZONES"

  if [ ${#FORWARD_ZONES[@]} -eq 0 ]; then
      echo "Không có Forward Zone nào."
      pause
      return
  fi

  echo "Danh sách Forward Zones:"
  for i in "${!FORWARD_ZONES[@]}"; do
      echo "  $((i+1)). ${FORWARD_ZONES[$i]}"
  done

  echo
  read -p "Chọn số thứ tự Zone để xem records: " ZONE_INDEX
  if ! [[ $ZONE_INDEX =~ ^[0-9]+$ ]] || [ "$ZONE_INDEX" -lt 1 ] || [ "$ZONE_INDEX" -gt ${#FORWARD_ZONES[@]} ]; then
      error "Lựa chọn không hợp lệ!"
      pause
      return
  fi

  DOMAIN="${FORWARD_ZONES[$((ZONE_INDEX-1))]}"
  FORWARD_ZONE_FILE="$ZONE_DIR/forward.${DOMAIN}"

  echo
  echo "=== Records trong zone $DOMAIN ==="
  if [ -f "$FORWARD_ZONE_FILE" ]; then
      grep -E "IN[[:space:]]+(A|CNAME|MX)" "$FORWARD_ZONE_FILE" | while read -r HOST TYPE VALUE; do
          case "$HOST" in
              "@") HOSTNAME="$DOMAIN" ;;
              *)   HOSTNAME="$HOST.$DOMAIN" ;;
          esac
          echo " $HOSTNAME → $VALUE"
      done
  else
      error "Không tìm thấy file zone: $FORWARD_ZONE_FILE"
  fi
}

# Hàm chuẩn hoá block forwarders 1 dòng thành nhiều dòng
normalize_forwarders_block() {
    if grep -qE 'forwarders[[:space:]]*\{.*\};' "$NAMED_CONF"; then
        awk '
        {
            # Nếu là block forwarders trên 1 dòng
            if ($0 ~ /forwarders[[:space:]]*\{.*\};/) {
                # Lấy phần trong { ... }
                match($0, /forwarders[[:space:]]*\{(.*)\};/, arr)
                ips=arr[1]
                print "forwarders {"
                n = split(ips, ip_array, ";")
                for (i = 1; i <= n; i++) {
                    ip = ip_array[i]
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", ip)  # trim
                    if (ip != "") {
                        print "    " ip ";"
                    }
                }
                print "};"
            } else {
                print $0
            }
        }
        ' "$NAMED_CONF" > /tmp/named.conf.tmp && mv /tmp/named.conf.tmp "$NAMED_CONF"
    fi
}

# Hàm lấy danh sách IP trong block forwarders
get_existing_forwarders() {
    awk '
    /forwarders[[:space:]]*\{/ { in_block=1; next }
    in_block && /\}/ { in_block=0; next }
    in_block { gsub(/[[:space:];]/, "", $0); print }
    ' "$NAMED_CONF"
}

# Hàm thêm IP mới vào forwarders nếu chưa có
add_forwarder_ip() {
    local new_ip=$1
    local exists=0

    # Lấy danh sách IP đã có
    existing_ips=$(get_existing_forwarders)

    for ip in $existing_ips; do
        if [ "$ip" == "$new_ip" ]; then
            exists=1
            break
        fi
    done

    if [ "$exists" -eq 1 ]; then
        echo "[INFO] IP $new_ip đã tồn tại trong forwarders."
    else
        # Thêm IP trước dòng chứa }
        awk -v ip="$new_ip" '
        /forwarders[[:space:]]*\{/ { in_block=1; print; next }
        in_block && /\}/ {
            printf "    %s;\n", ip
            in_block=0
        }
        { print }
        ' "$NAMED_CONF" > /tmp/named.conf.tmp && mv /tmp/named.conf.tmp "$NAMED_CONF"
		systemctl restart named
        echo "[SUCCESS] Đã thêm IP ${NEW_IP} vào forwarders."
    fi
}

# Hàm tạo block forwarders nếu chưa có
create_forwarders_block() {
	local new_ip=$1
	awk -v ip="${new_ip}" '
	/options[[:space:]]*\{/ {
	print
	print "    forwarders { " ip "; };"
	next
	}
	{ print }
	' "${NAMED_CONF}" > "${NAMED_CONF}.tmp"

	mv "${NAMED_CONF}.tmp" "${NAMED_CONF}"
	systemctl restart named
    echo "[SUCCESS] Đã thêm IP ${new_ip} vào forwarders."
}

add_forwarder() {
	read -rp "Nhập IP forwarder cần thêm: " NEW_IP

	if ! validate_ip "${NEW_IP}"; then
		echo "[ERROR] IP không hợp lệ."
		return 1
	fi

	if grep -q "forwarders[[:space:]]*{" "${NAMED_CONF}"; then
		normalize_forwarders_block
		add_forwarder_ip "${NEW_IP}"
	else
		create_forwarders_block "${NEW_IP}"
	fi
}
# ========== Menu set up dns==========
show_menu_setup_dns() {
	clear
	echo "==================== MENU_CẤU_HÌNH_DNS ===================="
	echo -e "1) Cài đặt và cấu hình DNS Server."
	echo -e "2) Tạo Forward Zone mới."
	echo -e "3) Kiểm tra trạng thái DNS."
	echo -e "4) Xem danh sách Zones."
	echo -e "5) Xem Records của Zone."
	echo -e "6) Thêm địa chỉ IP vào forwarders."
	echo -e "0) Thoát."
	echo "==========================================================="
}

menu_setup_dns() {
	echo "==================== MENU_CẤU_HÌNH_DNS ===================="
	# ===== Kiểm tra trạng thái cài đặt các gói tin =====
	if ! is_all_installed; then
		echo "[ERROR] Một số gói tin cần thiết chưa được cài đặt!"
		echo "[INFO]  Vui lòng sử dụng chức năng \"1. Cài đặt\"."
		echo "==========================================================="
		pause
		return 1
	fi
	while true; do
		show_menu_setup_dns
		read -p "Chọn chức năng [0-6]: " choice
		case $choice in
			1) setup_dns_server ; pause2 ;;
			2) create_forward_zone ; pause2 ;;
			3) systemctl status named --no-pager ; pause2 ;;
			4) list_zones ; pause2 ;;
			5) list_records ; pause2 ;;
			6) add_forwarder ; pause2 ;;
			0) break ;;
			*) error "Lựa chọn không hợp lệ!"; pause2 ;;
		esac
	done
}

#Kiểm tra trạng thái cài đặt package
is_installed() {
	local pkg=$1
	rpm -q "$pkg" &> /dev/null
	return $?
}

is_all_installed() {
	for pkg in "${PACKAGES[@]}"; do
		if ! is_installed "$pkg"; then
			return 1
		fi
	done
	return 0
}

#Kiểm tra trạng thái cài đặt tất cả packages
check_packages_installed() {
	echo "======== Trạng thái cài đặt của các gói tin ========"
	local MISSING_PACKAGES=();
	for pkg in "${PACKAGES[@]}"; do
		if is_installed "$pkg"; then
			echo "[INSTALLED] $pkg đã được cài đặt"
		else
			MISSING_PACKAGES+=("$pkg")
		fi
	done
	
	for pkg in "${MISSING_PACKAGES[@]}"; do
		echo "[NOT INSTALLED] $pkg chưa được cài đặt"
	done
	echo "===================================================="
}

#Cài đặt package
install_package() {
	local pkg=$1
	local status=0
	if ! is_installed "$pkg"; then
		echo "[INSTALLING] Đang cài đặt $pkg..."
		yum -y install "$pkg" &> /dev/null
		status=$?
		#Nếu không cài được epel-release thì phải cài qua URL trực tiếp
		if [[ $status -ne 0 && "$pkg" == "epel-release" ]]; then
			yum -y install "$EXTERNAL_LINK_EPEL_RELEASE" &> /dev/null
			status=$?
		fi
	fi
	if [ $status -ne 0 ]; then
		echo "[ERROR] Lỗi khi cài đặt $pkg."
		return 1
	fi
	return 0;
}

#Cài đặt tất cả packages
install_all_packages() {
	echo "============ Quá trình cài đặt các gói tin ============"
	if ! check_network_connection; then
		echo "[ERROR] Lỗi kết nối mạng."
		echo "[INFO]  Vui lòng kiểm tra kết nối mạng để tiến hành cài đặt."
		echo "======================================================="
		return 1
	fi
	local ERROR_PACKAGES=()
	for pkg in "${PACKAGES[@]}"; do
		if ! install_package "$pkg"; then
			ERROR_PACKAGES+=("$pkg")
		fi
	done
	if [ "${#ERROR_PACKAGES[@]}" -ne 0 ]; then
		echo "======= Tổng kết lỗi khi cài đặt ======="
		for pkg in "${ERROR_PACKAGES[@]}"; do
			echo "[ERROR] $pkg có lỗi khi cài đặt."
		done
		echo "======================================================="
		echo "[INFO] Vui lòng kiểm tra các files trong /etc/yum.repos.d, đường dẫn \"mirrorlist.centos.org\" không còn được sử dụng."
		echo "[INFO] Gợi ý chuyển sang đường dẫn \"vault.centos.org\."
		echo "[INFO] Bạn có thể tìm kiếm \"mirrorlist.centos.org no longer resolve?\" trên Internet."
	else
		echo "[SUCCESS] Các gói tin đã được cài đặt thành công!"
		echo "======================================================="
	fi
}

#Menu cho chuc nang 1 - Cai Dat
menu_install() {
	while true; do
		clear
		echo "============ MENU_CÀI_ĐẶT ============"
		echo "1) Kiểm tra các gói tin."
		echo "2) Cài đặt các gói tin."
		echo "0) Thoát cài đặt."
		echo "======================================"
		echo -n "Nhập lựa chọn [0-2]: "
		read choice
		clear
		case "$choice" in
			1)		
				check_packages_installed
				pause
				;;
			
			2)
				install_all_packages
				pause
				;;
			0)
				break;
				;;
			
			*)
				echo "[ERROR] Vui lòng chọn 0-2."
				pause
				;;
		esac
	done	
}

append_config() {
	local _file=$1
	local key=$2
	local value=$3
	local pattern="^${key}"

	readonly _file key value pattern
	if ! grep -Fxq "${key} = ${value}" "${_file}"; then
		sed -i -E "/${pattern}/ s|^|#|" "${_file}"
		echo "${key} = ${value}" >> "${_file}"
	fi
}

backup_file() {
	local _FILE=$1
	local BACKUP_FILE="${_FILE}.bak"
	if [ ! -f "${BACKUP_FILE}" ]; then
		cp "${_FILE}" "${BACKUP_FILE}"
	fi
}

# ===== Function: Lấy IP từ DNS =====
resolve_ip() {
	dig +short +time=1 +tries=1 "$1" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n1
}

# Hàm kiểm tra domain hợp lệ
validate_domain() {
    local DOMAIN="$1"

    if [[ "${DOMAIN}" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

config_squirrelmail() {
	local DOMAIN=$1
	local CONFIG_FILE="/etc/squirrelmail/config.php"
	readonly CONFIG_FILE DOMAIN
	sed -i "s|^\$domain\s*=.*|\$domain = \'${DOMAIN}\';|" "${CONFIG_FILE}"
}

config_postfix() {
	local POSTFIX_FILE="/etc/postfix/main.cf"
	readonly POSTFIX_FILE
	backup_file "${POSTFIX_FILE}"
	
	read -rp "Nhập hostname (VD: server.example.com): " HOSTNAME
	if ! validate_domain "${HOSTNAME}"; then
		echo "[ERROR] hostname không hợp lệ!"
		echo "[INFO]  hostname phải theo định dạng (VD: server.example.com)"
		return 1
	fi

	read -rp "Nhập domain (VD: example.com): " DOMAIN
	if ! validate_domain "${DOMAIN}"; then
		echo "[ERROR] DOMAIN không hợp lệ!"
		echo "[INFO]  DOMAIN phải theo định dạng (VD: example.com)"
		return 1
	fi

#	echo "[INFO] Đang kiểm tra DNS..."
#	local HOSTNAME_IP=$(resolve_ip "${HOSTNAME}")
#	local DOMAIN_IP=$(resolve_ip "${DOMAIN}")
#	
#	if [[ -z "${HOSTNAME_IP}" ]]; then
#		echo ""
#		echo "[ERROR] Hostname ${HOSTNAME} không có bản ghi DNS hoặc không trỏ tới IP của Mail Server!"
#		echo "[INFO]  Hãy đảm bảo ${HOSTNAME} có bản ghi trỏ về IP của Mail Server này."
#		return 1
#	fi
#	
#	if [[ -z "${DOMAIN_IP}" ]]; then
#		echo ""
#		echo "[ERROR] Domain ${DOMAIN} không có bản ghi DNS hoặc không trỏ tới IP của Mail Server!"
#		echo "[INFO]  Hãy đảm bảo ${DOMAIN} có bản ghi trỏ về IP của Mail Server này."
#		return 1
#	fi
#	echo "[SUCCESS] Kiểm tra DNS thành công!"
#	echo ""
#	echo "${HOSTNAME} -> ${HOSTNAME_IP}"
#	echo "${DOMAIN} -> ${DOMAIN_IP}"
#	echo ""
	echo "[ATTENTION] Chú ý đảm bảo IP của \"${HOSTNAME}\" là IP của Mail Server này!"
#	echo ""
	echo "[CONFIGURING] Đang cấu hình postfix..."
	postconf -e "myhostname = ${HOSTNAME}"
	postconf -e "mydomain = ${DOMAIN}"
	postconf -e "myorigin = \$mydomain"
	postconf -e "inet_interfaces = all"
	postconf -e "inet_protocols = all"
	postconf -e "mydestination = \$myhostname, localhost.\$mydomain, localhost, \$mydomain"
	postconf -e "mynetworks = 192.168.1.0/24, 127.0.0.0/8"
	postconf -e "home_mailbox = Maildir/"

	config_squirrelmail "${DOMAIN}"

	systemctl enable postfix &> /dev/null
	systemctl start postfix &> /dev/null
#	return 0
}

config_dovecot() {
	local DOVECOT_FILE="/etc/dovecot/dovecot.conf"
	local MAIL_FILE="/etc/dovecot/conf.d/10-mail.conf"
	local AUTH_FILE="/etc/dovecot/conf.d/10-auth.conf"
	local MASTER_FILE="/etc/dovecot/conf.d/10-master.conf"
	
	backup_file "${DOVECOT_FILE}"
	backup_file "${MAIL_FILE}"
	backup_file "${AUTH_FILE}"
	backup_file "${MASTER_FILE}"

	readonly DOVECOT_FILE MAIL_FILE AUTH_FILE MASTER_FILE
	local WS="[[:space:]]"

	echo "[CONFIGURING] Đang cấu hình dovecot..."
	append_config "${DOVECOT_FILE}" "protocols" "imap pop3 lmtp"
	append_config "${MAIL_FILE}" "mail_location" "maildir:~/Maildir"
	append_config "${AUTH_FILE}" "disable_plaintext_auth" "yes"
	append_config "${AUTH_FILE}" "auth_mechanisms" "plain login"

	local START_BLOCK="/^service dict {/"
	local END_BLOCK="/^}/"
	readonly START_BLOCK END_BLOCK

	sed -i "${START_BLOCK},${END_BLOCK} s|user.*|user = postfix|" "${MASTER_FILE}"
	sed -i "${START_BLOCK},${END_BLOCK} s|#${WS}*user.*|user = postfix|" "${MASTER_FILE}"
	sed -i "${START_BLOCK},${END_BLOCK} s|group.*|group = postfix|" "${MASTER_FILE}"
	sed -i "${START_BLOCK},${END_BLOCK} s|#${WS}*group.*|group = postfix|" "${MASTER_FILE}"

	systemctl enable dovecot &> /dev/null
	systemctl start dovecot &> /dev/null
}

config_httpd() {
	local HTTPD_FILE="/etc/httpd/conf/httpd.conf"
	readonly HTTPD_FILE
	backup_file "${HTTPD_FILE}"

	echo "[CONFIGURING] Đang cấu hình httpd..."
	if ! grep -Fxq "Alias /webmail /usr/share/squirrelmail" "${HTTPD_FILE}"; then
		echo "Alias /webmail /usr/share/squirrelmail"	>>	"${HTTPD_FILE}"
		echo "<Directory /usr/share/squirrelmail>"		>>	"${HTTPD_FILE}"
		echo 	"Options Indexes FollowSymLinks"		>>	"${HTTPD_FILE}"
		echo 	"RewriteEngine On"						>>	"${HTTPD_FILE}"
		echo 	"AllowOverride All"						>>	"${HTTPD_FILE}"
		echo 	"DirectoryIndex index.php"				>>	"${HTTPD_FILE}"
		echo 	"Order allow,deny"						>>	"${HTTPD_FILE}"
		echo 	"Allow from all"						>>	"${HTTPD_FILE}"
		echo "</Directory>"								>>	"${HTTPD_FILE}"
	fi

	systemctl enable httpd &> /dev/null
	systemctl start httpd &> /dev/null
}

restart_services() {
	echo "[CONFIGURING] Đang khởi động lại các dịch vụ"
	systemctl start firewalld &> /dev/null
	firewall-cmd --permanent --add-port=80/tcp &> /dev/null
	firewall-cmd --permanent --add-port=25/tcp &> /dev/null
	firewall-cmd --reload &> /dev/null
	systemctl restart named &> /dev/null
	systemctl restart postfix &> /dev/null
	systemctl restart dovecot &> /dev/null
	systemctl restart httpd &> /dev/null
	/usr/sbin/setsebool httpd_can_network_connect=1
	setsebool -P httpd_can_sendmail=1
}

config_mailserver() {
	echo "=========== Quá trình cấu hình Mail Server ==========="
	# ===== Kiểm tra trạng thái cài đặt các gói tin =====
	if ! is_all_installed; then
		echo "[ERROR] Một số gói tin cần thiết chưa được cài đặt!"
		echo "[INFO]  Vui lòng sử dụng chức năng \"1. Cài đặt\"."
		echo "====================================================="
		return 1
	fi
	
	echo "[ATTENTION] Hãy đảm bảo Mail Server sử dụng IP tĩnh trước khi cấu hình Mail Server!"
	echo ""

	config_postfix
	config_dovecot
	config_httpd
	restart_services

	local DOMAIN=$(postconf myhostname 2>/dev/null | awk '{print $3}')
	if [ -z "${DOMAIN}" ]; then
		echo "[ERROR] Không tìm thấy domain trong Postfix!"
		echo "[INFO]  Vui lòng cấu hình lại và chú ý các thông báo."
	else
		echo "[SUCCESS] Đã hoàn tất cấu hình Mail Server"
		echo "[INFO] Bạn có thể truy cập vào \"${DOMAIN}/webmail\" để gửi/nhận mail"

	fi
	
	echo "====================================================="
}

create_user() {
	read -rp "Nhập username: " USERNAME

	if [[ -z "${USERNAME}" ]]; then
		echo "[ERROR] Username không được để trống!"
		return 1
	fi

	if id "${USERNAME}" &>/dev/null; then
		echo "[ERROR] User ${USERNAME} đã tồn tại!"
		return 1
	fi

	useradd "${USERNAME}" &> /dev/null

	if [[ $? -ne 0 ]]; then
		echo "[ERROR] Tạo user thất bại!"
		return 1
	fi
	
	
	while true; do
		read -rsp "Nhập mật khẩu cho user: " PASSWORD
		echo
		read -rsp "Xác nhận mật khẩu: " PASSWORD2
		echo
		if [[ "${PASSWORD}" != "${PASSWORD2}" ]]; then
			echo "[ERROR] Mật khẩu không khớp!"
			continue
		fi
		break
	done
	echo "${USERNAME}:${PASSWORD}" | chpasswd
	echo "User ${USERNAME} đã được tạo thành công!"
}

#Menu chinh
menu_main() {
	#Kiểm tra người dùng root
	if [ "$(id -u)" -ne 0 ]; then
		echo "Bạn cần chạy chương trình dưới quyền root (sudo)!"
		exit 1
	fi

	sed -i "s|^SELINUX[[:space:]]*=.*|SELINUX=disabled|" "/etc/sysconfig/selinux"
	while true; do
		clear
		echo "================ MENU ================"
		echo "1) Cài đặt."
		echo "2) Cấu hình DNS Server."
		echo "3) Cấu hình Mail Server."
		echo "4) Tạo user."
		echo "0) Thoát."
		echo "======================================"
		echo -n "Nhập lựa chọn [0-4]: "
		read choice
		clear
		case "$choice" in
			1)		
				menu_install
				;;
			2)
				menu_setup_dns
				;;
			3)
				config_mailserver
				pause
				;;
			4)
				create_user
				pause
				;;
			0)
				echo "Đã thoát chương trình!"
				exit 0
				;;
			
			*)
				echo "[ERROR] Vui lòng chọn 0-4."
				pause
				;;
		esac
	done
}



#Chương trình chính
menu_main
