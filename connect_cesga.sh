#!/usr/bin/expect -f
# connect_cesga.expect

# =========================
# 0) Config
# =========================
set SUDO_PASSWORD "******"
set VPN_PASSWORD  "******"
set SSH_PASSWORD  "********"

set USERNAME      "__________"
set SNX_BIN       "/usr/bin/snx" ;# check your path
set SERVER        "secure.cesga.es"

set HOST_FTE      "ft3.cesga.es"
set HOST_HDP      "hdp.cesga.es"   

# Timeouts (Sekunden)
set DEFAULT_TIMEOUT 60
set SNX_TIMEOUT     180
set SSH_TIMEOUT     60

# =========================
# 1) Start SNX (VPN)
# =========================
set timeout $SNX_TIMEOUT
send_user "\nINFO: Starte SNX (VPN) via sudo ...\n"

spawn sudo $SNX_BIN -s $SERVER -u $USERNAME

set snx_ok 0

expect {
  -re {\[sudo\] password.*:} {
    send -- "$SUDO_PASSWORD\r"
    exp_continue
  }
  -re {Please enter your password:} {
    send -- "$VPN_PASSWORD\r"
    exp_continue
  }
  -re {Do you accept\?} {
    send -- "y\r"
    exp_continue
  }

  -re {Another session of SNX is already running} {
    send_user "\nINFO: SNX läuft bereits – mache weiter.\n"
    set snx_ok 1
  }

  -re {SNX started|connected|Connection (?:is )?up|Office Mode IP|Session opened} {
    send_user "\nINFO: SNX verbunden.\n"
    set snx_ok 1
  }

  -re {Login failed|Authentication failed|denied} {
    send_user "\nERROR: VPN-Login fehlgeschlagen.\n"
    exit 1
  }

  timeout {
    send_user "\nERROR: Timeout beim VPN-Connect (SNX).\n"
    exit 1
  }
}

if {!$snx_ok} {
  send_user "\nWARN: Kein eindeutiges 'connected' von SNX erkannt. Ich versuche trotzdem SSH.\n"
}

set timeout $DEFAULT_TIMEOUT

# =========================
# 2) Ask target
# =========================
send_user "\nVerbinden mit (hdp = Hadoop3 / fte = FinisTerraeIII) ? "
expect_user -re {([^\r\n]+)\r?\n}
set choice [string tolower [string trim $expect_out(1,string)]]

if {$choice eq "fte"} {
  set HOST $HOST_FTE
} elseif {$choice eq "hdp"} {
  set HOST $HOST_HDP
} else {
  send_user "\nERROR: Ungültige Auswahl: '$choice' (nur hdp oder fte)\n"
  exit 1
}

# =========================
# 3) SSH login
# =========================
set timeout $SSH_TIMEOUT
send_user "\nINFO: Starte SSH: $USERNAME@$HOST\n"

spawn ssh -tt -o StrictHostKeyChecking=accept-new $USERNAME@$HOST

expect {
  -re {Are you sure you want to continue connecting.*\(yes/no\)\?} {
    send -- "yes\r"
    exp_continue
  }
  -re {(?i)password:} {
    send -- "$SSH_PASSWORD\r"
    exp_continue
  }
  -re {[\$#] $} {
    # prompt erkannt
  }
  timeout {
    send_user "\nERROR: Timeout bei SSH-Login.\n"
    exit 1
  }
}

# TTY aufräumen (falls snx/sudo es verstellt hat)
catch {exec stty sane}
catch {exec stty echo}

# =========================
# 4) Interactive session
# =========================
send_user "\nINFO: Interaktiver Modus. Beenden mit 'exit'. Suspend SSH mit Enter, dann '~^Z'.\n"
interact#!/usr/bin/expect -f
# connect_cesga.expect

# =========================
# 0) Config
# =========================
set SUDO_PASSWORD "1234"
set VPN_PASSWORD  "Finis26+"
set SSH_PASSWORD  "Finis26+"

set USERNAME      "othcxlwa"
set SNX_BIN       "/usr/bin/snx"
set SERVER        "secure.cesga.es"

set HOST_FTE      "ft3.cesga.es"
set HOST_HDP      "hdp.cesga.es"   ;# ggf. anpassen

# Timeouts (Sekunden)
set DEFAULT_TIMEOUT 60
set SNX_TIMEOUT     180
set SSH_TIMEOUT     60

# =========================
# 1) Start SNX (VPN)
# =========================
set timeout $SNX_TIMEOUT
send_user "\nINFO: Starte SNX (VPN) via sudo ...\n"

spawn sudo $SNX_BIN -s $SERVER -u $USERNAME

set snx_ok 0

expect {
  -re {\[sudo\] password.*:} {
    send -- "$SUDO_PASSWORD\r"
    exp_continue
  }
  -re {Please enter your password:} {
    send -- "$VPN_PASSWORD\r"
    exp_continue
  }
  -re {Do you accept\?} {
    send -- "y\r"
    exp_continue
  }

  -re {Another session of SNX is already running} {
    send_user "\nINFO: SNX läuft bereits – mache weiter.\n"
    set snx_ok 1
  }

  -re {SNX started|connected|Connection (?:is )?up|Office Mode IP|Session opened} {
    send_user "\nINFO: SNX verbunden.\n"
    set snx_ok 1
  }

  -re {Login failed|Authentication failed|denied} {
    send_user "\nERROR: VPN-Login fehlgeschlagen.\n"
    exit 1
  }

  timeout {
    send_user "\nERROR: Timeout beim VPN-Connect (SNX).\n"
    exit 1
  }
}

if {!$snx_ok} {
  send_user "\nWARN: Kein eindeutiges 'connected' von SNX erkannt. Ich versuche trotzdem SSH.\n"
}

set timeout $DEFAULT_TIMEOUT

# =========================
# 2) Ask target
# =========================
send_user "\nVerbinden mit (hdp = Hadoop3 / fte = FinisTerraeIII) ? "
expect_user -re {([^\r\n]+)\r?\n}
set choice [string tolower [string trim $expect_out(1,string)]]

if {$choice eq "fte"} {
  set HOST $HOST_FTE
} elseif {$choice eq "hdp"} {
  set HOST $HOST_HDP
} else {
  send_user "\nERROR: Ungültige Auswahl: '$choice' (nur hdp oder fte)\n"
  exit 1
}

# =========================
# 3) SSH login
# =========================
set timeout $SSH_TIMEOUT
send_user "\nINFO: Starte SSH: $USERNAME@$HOST\n"

spawn ssh -tt -o StrictHostKeyChecking=accept-new $USERNAME@$HOST

expect {
  -re {Are you sure you want to continue connecting.*\(yes/no\)\?} {
    send -- "yes\r"
    exp_continue
  }
  -re {(?i)password:} {
    send -- "$SSH_PASSWORD\r"
    exp_continue
  }
  -re {[\$#] $} {
    # prompt erkannt
  }
  timeout {
    send_user "\nERROR: Timeout bei SSH-Login.\n"
    exit 1
  }
}

# TTY aufräumen (falls snx/sudo es verstellt hat)
catch {exec stty sane}
catch {exec stty echo}

# =========================
# 4) Interactive session
# =========================
send_user "\nINFO: Interaktiver Modus. Beenden mit 'exit'. Suspend SSH mit Enter, dann '~^Z'.\n"
interact
