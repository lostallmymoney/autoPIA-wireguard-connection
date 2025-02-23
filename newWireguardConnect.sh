#!/bin/sh

SERVERLIST=$(curl -s "https://serverlist.piaservers.net/vpninfo/servers/v4" | awk '/^{/,/}]}/')
REGION_IDS=$(echo "$SERVERLIST" | jq -r '.regions[].id')

NETRC_FILE="$HOME/.netrc"
PIA_MACHINE="privateinternetaccess.com"

get_valid_region() {
  while true; do
    echo "Available Regions:"
    echo "$REGION_IDS" | nl -w2 -s'. ' # Numbered list for readability

    echo "Enter a valid region ID from the list: "
    read -r REGION_ID

    # Validate the entered region
    if echo "$REGION_IDS" | grep -q "^$REGION_ID$"; then
      break # Valid region, exit loop
    else
      echo "❌ Invalid region ID. Please try again."
    fi
  done
}
set_credentials() {
  # Check if credentials already exist
  if grep -q "machine $PIA_MACHINE" "$NETRC_FILE" 2>/dev/null; then
    echo "Credentials for $PIA_MACHINE already exist in $NETRC_FILE."
  else
    # Read username
    echo "Enter PIA username:"
    read -r username

    # Read password securely (POSIX-compatible)
    echo "Enter PIA password:"
    stty -echo # Disable input echo (hides password)
    read -r password
    stty echo # Re-enable input echo
    echo ""   # Print a newline

    # Append credentials to .netrc securely
    echo "" | tee -a "$NETRC_FILE" >/dev/null
    printf "machine %s\nlogin %s\npassword %s\n" "$PIA_MACHINE" "$username" "$password" | tee -a "$NETRC_FILE" >/dev/null
    echo "Credentials saved securely."
  fi
}
reset_authentification() {
  # Ensure the file exists before modifying
  if [ ! -f "$NETRC_FILE" ]; then
    echo "No .netrc file found."
  else
    # Remove only the PIA credentials safely
    sudo cp "$NETRC_FILE" "$NETRC_FILE.bak"
    sudo sed -i "/machine $PIA_MACHINE/,+2d" "$NETRC_FILE"
    echo "Credentials removed. Backup saved as $NETRC_FILE.bak."
  fi
}

reload_token_full() {

  PIA_TOKEN=$(
    curl -s --tls-max 1.3 --netrc-file "$HOME/.netrc" \
      "https://privateinternetaccess.com/gtoken/generateToken" | jq -r '.token'
  )
  reloadedCredentials=true
  if [ ! "${#PIA_TOKEN}" -eq 124 ]; then
    echo "Warning: PIA_TOKEN length too short."
    reloadedCredentials=false
  fi

  if [ -z "$PIA_TOKEN" ] || [ "$PIA_TOKEN" = "null" ] || [ "$reloadedCredentials" = false ]; then

    echo "Failed to retrieve PIA token."

    while ! $reloadedCredentials; do
      echo "Do you want to reset your credentials? (y/n): "
      read -r answer
      case $answer in
      [Yy]*)
        echo "Resetting credentials..."
        # Call reset credentials logic here, e.g., reset_authentification and set_credentials functions
        reset_authentification
        set_credentials
        break
        ;;
      [Nn]*)
        echo "Credentials will not be reset."
        break
        ;;
      *)
        echo "Please answer with y or n."
        ;;
      esac
    done
    exit 1
  fi

  echo "$PIAIP"
  echo "$PIACN"
  echo "$PIA_TOKEN" > PIA_TOKEN
  chmod 600 PIA_TOKEN
}

# If no argument is provided, enter interactive mode
if [ -z "$1" ]; then
  get_valid_region
else
  REGION_ID="$1"
fi

# Extract PIA IP and CN using jq directly from the variable
PIAIP=$(echo "$SERVERLIST" | jq -r --arg region "$REGION_ID" '.regions[] | select(.id==$region) | .servers.wg[0].ip')
PIACN=$(echo "$SERVERLIST" | jq -r --arg region "$REGION_ID" '.regions[] | select(.id==$region) | .servers.wg[0].cn')

# Check if values were found
if [ -z "$PIAIP" ] || [ -z "$PIACN" ]; then
  echo "Error: Region '$REGION_ID' not found or no WireGuard servers available."
  exit 1
fi

# Create .netrc if it doesn't exist, then set correct permissions
if [ ! -f "$NETRC_FILE" ]; then
  touch "$NETRC_FILE"
  chmod 600 "$NETRC_FILE"
fi

set_credentials

reloadedCredentials=false
PIA_TOKEN=$(cat PIA_TOKEN)
if [ -n "$PIA_TOKEN" ] && [ "$PIA_TOKEN" != "null" ]; then
  reloadedCredentials=true
  echo "Reloaded PIA_TOKEN from file.."
fi

if [ ! "${#PIA_TOKEN}" -eq 124 ]; then
  echo "Warning: PIA_TOKEN length seems too short."
  reloadedCredentials=false
fi
if [ ! $reloadedCredentials ]; then
  reload_token_full
fi

connectWireguard() {
  privKey="$(wg genkey)"
  export privKey
  pubKey="$(echo "$privKey" | wg pubkey)"
  export pubKey

  wireguard_json="$(curl -s -G \
    --connect-to "$PIACN::$PIAIP:" \
    --cacert "ca.rsa.4096.crt" \
    --data-urlencode "pt=${PIA_TOKEN}" \
    --data-urlencode "pubkey=$pubKey" \
    "https://${PIACN}:1337/addKey")"
  export wireguard_json
}

connectWireguard

if [ "$(echo "$wireguard_json" | jq -r '.status')" != "OK" ]; then
  printf "Server did not return OK. Trying reauth : .\n" >&2
  reload_token_full
  connectWireguard
fi
if [ "$(echo "$wireguard_json" | jq -r '.status')" != "OK" ]; then
  printf "Server did not return OK. Exiting : .\n" >&2
  exit 1
fi

printf "Server returned OK.\n" >&2

echo
echo Trying to disable a PIA WG connection in case it exists...
sudo wg-quick down pia && printf "\nPIA WG connection disabled!"
echo

if [ "$PIA_DNS" = "true" ]; then
  dnsServer=$(echo "$wireguard_json" | jq -r '.dns_servers[0]')
  echo "Trying to set up DNS to $dnsServer. In case you do not have resolvconf,"
  echo "this operation will fail and you will not get a VPN. If you have issues,"
  echo "start this script without PIA_DNS."
  echo
  dnsSettingForVPN="DNS = $dnsServer"
fi

printf "Trying to write /etc/wireguard/pia.conf..."
mkdir -p /etc/wireguard
echo "
[Interface]
Address = $(echo "$wireguard_json" | jq -r '.peer_ip')
PrivateKey = $privKey
$dnsSettingForVPN
[Peer]
PersistentKeepalive = 25
PublicKey = $(echo "$wireguard_json" | jq -r '.server_key')
AllowedIPs = 0.0.0.0/0
Endpoint = ${PIAIP}:$(echo "$wireguard_json" | jq -r '.server_port')
" | sudo tee /etc/wireguard/pia.conf >/dev/null || exit 1
printf "OK!\n"

echo
echo Trying to create the wireguard interface...
sudo wg-quick up pia || exit 1
echo
printf "The WireGuard interface got created with internet.\n To disconnect the VPN, run:--> wg-quick down pia <--\n"

# This section will stop the script if PIA_PF is not set to "true".
if [ "$PIA_PF" != "true" ]; then
  printf "If you want to also enable port forwarding, you can start the script : \n./port_forwarding.sh:\n"
  printf "PF_GATEWAY=%s \nPF_HOSTNAME=%s \n" "$PIAIP" "$PIACN"

  echo
  echo The location used must be port forwarding enabled, or this will fail.
  echo Calling the ./get_region script with PIA_PF=true will provide a filtered list.
  exit 1
fi

printf "This script got started with PIA_PF=true.\n\nStarting port forwarding in "
# Countdown loop
for i in 5 4 3 2 1; do
  printf "%s..." "$i"
  sleep 1
done
printf "\n\n"

printf "Starting procedure to enable port forwarding by running the following command:\nPIA_TOKEN=%s \\\n  PF_GATEWAY=%s \\\n  PF_HOSTNAME=%s \\\n  ./port_forwarding.sh\n" "$PIA_TOKEN" "$PF_GATEWAY" "$PF_HOSTNAME"

PIA_TOKEN=$PIA_TOKEN \
  PF_GATEWAY=$PIAIP \
  PF_HOSTNAME=$PIACN \
  ./port_forwarding.sh
