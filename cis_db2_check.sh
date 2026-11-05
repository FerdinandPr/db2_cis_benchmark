#!/bin/bash
# =============================================================================
# cis_db2_check.sh
#
# Lesende Konfigurationspruefung einer Db2-LUW-Instanz (Linux) gegen die
# automatisierbaren Empfehlungen des CIS IBM Db2 11 Benchmark v1.2.0
# (Profile: Linux OS Level / Database Level) und weitgehend kompatibel mit
# dem CIS IBM Db2 12.1 Benchmark v1.0.0.
#
# Eigenschaften:
#   - NUR LESEND: das Skript aendert keine Konfiguration und keine Datenbank.
#   - Manuelle CIS-Pruefungen werden als INFO mit Ist-Wert ausgegeben.
#   - Die Abschnitts-IDs in der Ausgabe entsprechen der Benchmark-Gliederung.
#
# Voraussetzungen:
#   - Ausfuehrung als Db2-Instanzowner (z. B. db2inst1) unter Linux
#   - db2 CLP verfuegbar (ggf. wird ~/sqllib/db2profile gesourced)
#   - Fuer die Datenbank-Pruefungen (Abschnitt 4-7): lokale katalogisierte DB
#
# Aufruf:
#   ./cis_db2_check.sh [-d DATENBANK] [-o REPORT.txt] [--csv ERGEBNIS.csv]
#
#   -d  zu pruefende Datenbank (Default: erste lokal katalogisierte DB)
#   -o  Report zusätzlich in Datei schreiben
#   --csv  Ergebnis zusätzlich als CSV (Status;CIS-ID;Befund)
#
# Exit-Code: 0 = kein FAIL, 1 = mindestens ein FAIL, 2 = Abbruch (Preflight)
#
# Hinweis: Die erwarteten Werte stehen unten im Konfigurationsblock und
# orientieren sich am CIS-Benchmark. Massgeblich bleibt das offizielle
# CIS-PDF (kostenlos bei CIS verfuegbar); dort nicht eindeutig verifizierbare
# Punkte werden als WARN/INFO statt FAIL ausgegeben.
# =============================================================================

set -u
LC_ALL=C

# ----------------------- Erwartungswerte (anpassbar) ------------------------
EXP_UMASK=027                # 3.3.3  umask des Instanzowners
MIN_DIAGLEVEL=3              # 3.1.3  DIAGLEVEL Minimum
MIN_NOTIFYLEVEL=3            # 3.1.9  NOTIFYLEVEL Minimum
EXP_ARCHRETRYDELAY=100       # 4.1.2  ARCHRETRYDELAY Minimum
MIN_NUMARCHRETRY=5           # 4.1.11 NUMARCHRETRY Minimum
CATALOG_SCHEMAS="'SYSCAT','SYSSTAT','SYSIBM','SYSIBMADM'"
ROUTINE_SCHEMAS="'SYSPROC','SYSFUN'"
MAX_EXAMPLES=15              # max. Beispiele bei aggregierten Befunden

# ------------------------------- Zaehler ------------------------------------
PASS_CNT=0; FAIL_CNT=0; WARN_CNT=0; INFO_CNT=0
DB=""
DB_LEVEL=0                  # 1 = Datenbank-Checks moeglich
CSV_FILE=""
REPORT_FILE=""

usage() {
  cat <<'EOF'
cis_db2_check.sh — CIS-Benchmark-Pruefung fuer Db2 LUW (nur lesend)
Aufruf: ./cis_db2_check.sh [-d DATENBANK] [-o REPORT.txt] [--csv ERGEBNIS.csv]
EOF
}

# ------------------------------ Hilfsfunktionen ------------------------------
record() {  # record <PASS|FAIL|WARN|INFO> <CIS-ID> <Text>
  local st="$1" id="$2" msg="$3"
  case "$st" in
    PASS) PASS_CNT=$((PASS_CNT+1));;
    FAIL) FAIL_CNT=$((FAIL_CNT+1));;
    WARN) WARN_CNT=$((WARN_CNT+1));;
    INFO) INFO_CNT=$((INFO_CNT+1));;
  esac
  printf '[%-4s] %-7s %s\n' "$st" "$id" "$msg"
  if [ -n "$CSV_FILE" ]; then
    printf '%s;%s;"%s"\n' "$st" "$id" "${msg//\"/\'}" >>"$CSV_FILE"
  fi
}

sec() {  # Abschnittsueberschrift
  printf '\n== %s ==\n' "$1"
}

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

is_num() { [[ "$1" =~ ^[0-9]+$ ]]; }

db2set_val() {  # aktuellen Registry-Wert lesen (leer = nicht gesetzt)
  db2set "$1" 2>/dev/null | head -n1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

dbm_cfg() {  # DBM-Konfigurationsparameter (Instanzebene)
  db2 get dbm cfg 2>/dev/null | awk -v p="($1)" '
    index($0, p) != 0 { sub(/^[^=]*= */,""); gsub(/[[:space:]]+$/,""); print; exit }
  '
}

db_cfg() {  # DB-Konfigurationsparameter (Datenbankebene)
  db2 get db cfg for "$DB" 2>/dev/null | awk -v p="($1)" '
    index($0, p) != 0 { sub(/^[^=]*= */,""); gsub(/[[:space:]]+$/,""); print; exit }
  '
}

q() {  # SQL-Abfrage (db2 -x, ohne Spaltenkoepfe); braucht bestehende Verbindung
  db2 -x "$1" 2>/dev/null
}

mode_of()  { stat -Lc '%a' "$1" 2>/dev/null; }
owner_of() { stat -Lc '%U' "$1" 2>/dev/null; }

list_inline() {  # mehrzeilige Liste zu einem String kuerzen
  local n="$(( MAX_EXAMPLES / 2 ))"
  { head -n "$n"; tail -n +$(( n + 1 )) | head -n "$n"; } 2>/dev/null \
    | paste -sd, - 2>/dev/null
}

# Pruefung: Verzeichnis ohne Gruppen-/Weltzugriff (Modus 700 empfohlen)
# check_secured_dir <CIS-ID> <Pfad> <Beschreibung> [StatusWennUngesetzt]
check_secured_dir() {
  local id="$1" path="$2" desc="$3" unset_st="${4:-INFO}"
  if [ -z "$path" ]; then
    record "$unset_st" "$id" "$desc nicht gesetzt — nichts zu pruefen"
    return
  fi
  if [ ! -e "$path" ]; then
    record WARN "$id" "$desc: Pfad '$path' existiert nicht"
    return
  fi
  local m own
  m=$(mode_of "$path"); own=$(owner_of "$path")
  if ! is_num "$m"; then
    record WARN "$id" "$desc: Modus von '$path' nicht lesbar"
    return
  fi
  if (( (8#$m & 8#077) == 0 )); then
    record PASS "$id" "$desc '$path': Modus $m, Besitzer $own — kein Gruppen-/Weltzugriff"
  else
    record FAIL "$id" "$desc '$path': Modus $m, Besitzer $own — Gruppen-/Weltzugriff entfernen (Empfehlung: 700)"
  fi
}

# Pruefung: Pfad nicht gruppen-/weltbeschreibbar (JDK/PYTHON/R, Logpfade)
# check_no_write <CIS-ID> <Pfad> <Beschreibung> [StatusWennUngesetzt]
check_no_write() {
  local id="$1" path="$2" desc="$3" unset_st="${4:-INFO}"
  if [ -z "$path" ]; then
    record "$unset_st" "$id" "$desc nicht gesetzt — nichts zu pruefen"
    return
  fi
  if [ ! -e "$path" ]; then
    record WARN "$id" "$desc: Pfad '$path' existiert nicht"
    return
  fi
  local m own
  m=$(mode_of "$path"); own=$(owner_of "$path")
  if is_num "$m" && (( (8#$m & 8#022) == 0 )); then
    record PASS "$id" "$desc '$path': Modus $m, Besitzer $own — nicht beschreibbar fuer Gruppe/Welt"
  else
    record FAIL "$id" "$desc '$path': Modus $m, Besitzer $own — Beschreibbarkeit fuer Gruppe/Welt entfernen"
  fi
}

# Registry-Variable, die laut CIS NICHT gesetzt sein darf
# check_reg_unset <CIS-ID> <Variable> <Beschreibung> [FAIL|WARN]
check_reg_unset() {
  local id="$1" var="$2" desc="$3" level="${4:-FAIL}"
  local v; v=$(db2set_val "$var")
  if [ -z "$v" ]; then
    record PASS "$id" "$desc: $var nicht gesetzt (empfohlen)"
  else
    record "$level" "$id" "$desc: $var='$v' — Empfehlung: Variable entfernen (db2set $var=)"
  fi
}

# DBM-/DB-CFG-Parameter mit erwartetem Wert (Groesse/Grossbuchstaben egal)
# check_cfg_eq <CIS-ID> <gueltigeWerte...> -- <Parameter> <Ist> <Beschreibung>
check_cfg_eq() {
  local id="$1"; shift
  local expected=()
  while [ "$1" != "--" ]; do expected+=("$1"); shift; done
  shift  # '--' entfernen
  local param="$1" actual="$2" desc="$3"
  local a; a=$(upper "$actual")
  local ok=0 want=""
  for e in "${expected[@]}"; do
    want+="${want:+ oder }$e"
    [ "$a" = "$(upper "$e")" ] && ok=1
  done
  if [ "$ok" -eq 1 ]; then
    record PASS "$id" "$desc: $param='$actual' (empfohlen)"
  else
    record FAIL "$id" "$desc: $param='$actual' — empfohlen: $want"
  fi
}

# ------------------------------- Argumente ----------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -d)      DB="$2"; shift 2;;
    -o)      REPORT_FILE="$2"; shift 2;;
    --csv)   CSV_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 2;;
  esac
done

[ -n "$CSV_FILE" ] && printf 'Status;CIS-ID;Befund\n' >"$CSV_FILE"
if [ -n "$REPORT_FILE" ]; then
  exec > >(tee "$REPORT_FILE") 2>&1
fi

# -------------------------------- Preflight ---------------------------------
sec "0 Preflight"

if [ ! -d "$HOME/sqllib" ]; then
  echo "FEHLER: Kein ~/sqllib gefunden. Skript als Db2-Instanzowner ausfuehren." >&2
  exit 2
fi
if ! command -v db2 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$HOME/sqllib/db2profile" 2>/dev/null || {
    echo "FEHLER: db2-CLP nicht verfuegbar." >&2; exit 2;
  }
fi

INST_USER=$(id -un)
VER=$(db2level 2>/dev/null | grep -oE 'DB2 v[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
echo "Instanzowner : $INST_USER"
echo "Db2-Version  : ${VER:-unbekannt}"

if [ -z "$DB" ]; then
  DB=$(db2 list db directory 2>/dev/null | awk -F= '
    /^ *Database name/ {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); db=$2}
    /Directory entry type/ && /Indirect/ && db != "" {print db; exit}')
fi

if [ -n "$DB" ]; then
  if db2 connect to "$DB" >/dev/null 2>&1; then
    DB_LEVEL=1
    echo "Datenbank    : $DB (verbunden)"
  else
    echo "Datenbank    : $DB — Verbindung fehlgeschlagen, DB-Checks werden uebersprungen"
  fi
else
  echo "Datenbank    : keine lokale DB gefunden — DB-Checks werden uebersprungen"
fi
[ "$DB_LEVEL" -eq 0 ] && record WARN "0" "Datenbank-Checks (CIS-Abschnitte 4.x/6.x/7.1.3) nicht moeglich"

# ======================= 1 INSTALLATION UND PATCHES ==========================
sec "1 Installation und Patch-Management (1.1)"
# 1.1.1 Install Available Updates (Manual): Versionsstand melden
record INFO "1.1.1" "Db2-Version '$VER' — Fixpack-Stand mit den aktuell bei IBM verfuegbaren Updates vergleichen und installieren"

# ============= 2 BETRIEBSSYSTEM / DB-BENUTZER (2.1) ==========================
sec "2 Betriebssystem (2.1)"
if [ "$DB_LEVEL" -eq 1 ]; then
  hits=""
  for a in $(q "SELECT DISTINCT RTRIM(GRANTEE) FROM SYSCAT.DBAUTH WHERE GRANTEETYPE='U'"); do
    shell=$(getent passwd "$a" 2>/dev/null | awk -F: '{print $7}')
    if [ -n "$shell" ] && [ "$shell" != "/sbin/nologin" ] && \
       [ "$shell" != "/usr/sbin/nologin" ] && [ "$shell" != "/bin/false" ]; then
      hits="$hits $a($shell)"
    fi
  done
  if [ -n "$hits" ]; then
    record INFO "2.1" "Folgende DB-Authids besitzen ein OS-Login (manuell bewerten):$hits"
  else
    record PASS "2.1" "Keine DB-Authids mit gleichzeitiger OS-Login-Moeglichkeit gefunden"
  fi
else
  record INFO "2.1" "Uebersprungen (keine DB-Verbindung)"
fi

# =============== 3 INSTANZKONFIGURATION (3.1 DBM CFG / 3.2 Registry) ==========
sec "3 Instanzkonfiguration (3.1 DBM CFG, 3.2 Registry, 3.3 Allgemein)"

# 3.1.1 Require Explicit Authorization for Cataloging (CATALOG_NOAUTH)
check_reg_unset "3.1.1" "CATALOG_NOAUTH" "Explizite Autorisierung fuer Cataloging"

# 3.1.2 Secure Permissions for Default Database File Path (DFTDBPATH)
check_secured_dir "3.1.2" "$(dbm_cfg DFTDBPATH)" "Default Database File Path (DFTDBPATH)" PASS

# 3.1.3 Set Diagnostic Logging to Capture Errors and Warnings (DIAGLEVEL)
v=$(dbm_cfg DIAGLEVEL)
if is_num "$v" && [ "$v" -ge "$MIN_DIAGLEVEL" ]; then
  record PASS "3.1.3" "DIAGLEVEL=$v (>= $MIN_DIAGLEVEL empfohlen)"
else
  record FAIL "3.1.3" "DIAGLEVEL='$v' — empfohlen: >= $MIN_DIAGLEVEL"
fi

# 3.1.4/3.1.5 Diagnostic-Log-Pfade absichern
check_secured_dir "3.1.4" "$(dbm_cfg DIAGPATH)" "Diagnostic Log Path (DIAGPATH)" PASS
check_secured_dir "3.1.5" "$(dbm_cfg ALT_DIAGPATH)" "Alternate Diagnostic Log Path (ALT_DIAGPATH)"

# 3.1.6 Disable Client Discovery Requests (DISCOVER)
check_cfg_eq "3.1.6" DISABLE -- "DISCOVER" "$(dbm_cfg DISCOVER)" "Client Discovery"

# 3.1.7 Disable Instance Discoverability (DISCOVER_INST)
check_cfg_eq "3.1.7" DISABLE -- "DISCOVER_INST" "$(dbm_cfg DISCOVER_INST)" "Instance Discoverability"

# 3.1.8 Set Maximum Connection Limits (MAX_CONNECTIONS / MAX_COORDAGENTS)
v=$(dbm_cfg MAX_CONNECTIONS)
if [ -z "$v" ] || [ "$(upper "$v")" = "AUTOMATIC" ]; then
  record WARN "3.1.8" "MAX_CONNECTIONS='$v' — Endliche Grenze setzen (Benchmark: Wert je nach Last festlegen)"
else
  record PASS "3.1.8" "MAX_CONNECTIONS=$v"
fi
v=$(dbm_cfg MAX_COORDAGENTS)
if [ -z "$v" ] || [ "$(upper "$v")" = "AUTOMATIC" ]; then
  record WARN "3.1.8" "MAX_COORDAGENTS='$v' — Endliche Grenze setzen"
else
  record PASS "3.1.8" "MAX_COORDAGENTS=$v"
fi

# 3.1.9 Set Administrative Notification Level (NOTIFYLEVEL)
v=$(dbm_cfg NOTIFYLEVEL)
if is_num "$v" && [ "$v" -ge "$MIN_NOTIFYLEVEL" ]; then
  record PASS "3.1.9" "NOTIFYLEVEL=$v (>= $MIN_NOTIFYLEVEL empfohlen)"
else
  record WARN "3.1.9" "NOTIFYLEVEL='$v' — Empfehlung lt. Benchmark pruefen (Referenz >= $MIN_NOTIFYLEVEL)"
fi

# 3.1.10-3.1.12 Laufzeitpfade absichern (nicht beschreibbar fuer Gruppe/Welt)
check_no_write "3.1.10" "$(dbm_cfg JDK_PATH)"    "JDK-Pfad (JDK_PATH)"      PASS
check_no_write "3.1.11" "$(dbm_cfg PYTHON_PATH)" "Python-Runtime (PYTHON_PATH)" PASS
check_no_write "3.1.12" "$(dbm_cfg R_PATH)"      "R-Runtime (R_PATH)"       PASS

# 3.1.13 Secure the Communication Buffer Exit Library (COMM_EXIT_LIST)
check_reg_unset "3.1.13" "COMM_EXIT_LIST" "Communication Buffer Exit Library" WARN

# 3.2.1 Specify Secure Remote Shell Command (DB2RSHCMD)
v=$(db2set_val DB2RSHCMD)
if [ -z "$v" ]; then
  record WARN "3.2.1" "DB2RSHCMD nicht gesetzt — auf Pfad zu ssh setzen (db2set DB2RSHCMD=/usr/bin/ssh)"
elif printf '%s' "$v" | grep -qi 'ssh'; then
  record PASS "3.2.1" "DB2RSHCMD='$v' (ssh)"
else
  record FAIL "3.2.1" "DB2RSHCMD='$v' — auf ssh umstellen (kein rsh/rcp)"
fi

# 3.2.2 Turn Off Remote Command Legacy Mode (DB2RCMD_LEGACY_MODE)
v=$(db2set_val DB2RCMD_LEGACY_MODE)
case "$(upper "$v")" in
  ""|FALSE|NO|OFF) record PASS "3.2.2" "DB2RCMD_LEGACY_MODE nicht gesetzt/aus (empfohlen)";;
  *)               record FAIL "3.2.2" "DB2RCMD_LEGACY_MODE='$v' — Legacy-Mode deaktivieren";;
esac

# 3.2.3 Disable Grants During Restore (DB2_RESTORE_GRANT_ADMIN_AUTHORITIES)
check_reg_unset "3.2.3" "DB2_RESTORE_GRANT_ADMIN_AUTHORITIES" "Grant-Admin-Authorities-bei-Restore"

# 3.2.4 Enable Extended Security (DB2_EXTSECURITY)
v=$(db2set_val DB2_EXTSECURITY)
case "$(upper "$v")" in
  TRUE|YES|ON) record PASS "3.2.4" "DB2_EXTSECURITY='$v' (aktiviert)";;
  *)           record FAIL "3.2.4" "DB2_EXTSECURITY='${v:-nicht gesetzt}' — empfohlen: TRUE";;
esac

# 3.2.5 Limit OS Privileges of Fenced Mode Process (DB2_LIMIT_FENCED_GROUP)
v=$(db2set_val DB2_LIMIT_FENCED_GROUP)
case "$(upper "$v")" in
  TRUE|YES|ON) record PASS "3.2.5" "DB2_LIMIT_FENCED_GROUP='$v' (aktiviert)";;
  *)           record FAIL "3.2.5" "DB2_LIMIT_FENCED_GROUP='${v:-nicht gesetzt}' — empfohlen: TRUE";;
esac

# 3.3.1 Secure Db2 Runtime Library (Manual): Best-Effort-Pruefung
check_no_write "3.3.1" "$HOME/sqllib" "Db2-Runtime-Bibliothek (~/sqllib)" PASS

# 3.3.2 Secure the Database Container Directory (Manual): Hinweis
record INFO "3.3.2" "Container-Verzeichnisse unter '$(dbm_cfg DFTDBPATH)' manuell pruefen (Instanzowner, 700)"

# 3.3.3 Set umask Value in the Db2 Instance Owner's .profile (Automated)
um_line=$(grep -iE '^[[:space:]]*umask[[:space:]]+[0-7]{3,4}' "$HOME/.profile" 2>/dev/null | tail -n1)
u_val=$(printf '%s' "$um_line" | awk '{print $2}')
case "$u_val" in
  027|0027|077|0077)
    record PASS "3.3.3" "umask $u_val in ~/.profile (mindestens $EXP_UMASK)";;
  *)
    record FAIL "3.3.3" "umask in ~/.profile ist '${u_val:-nicht gesetzt}' — 'umask $EXP_UMASK' ergaenzen";;
esac

# ==================== 4 DATENBANKKONFIGURATION (4.x) =========================
sec "4 Datenbankkonfiguration (4.1 DB CFG, 4.2-4.5 Katalog)"

if [ "$DB_LEVEL" -eq 1 ]; then

  # 4.1.1 Creating the Database Without PUBLIC Grants (RESTRICTIVE)
  n=$(trim "$(q "SELECT COUNT(*) FROM SYSCAT.DBAUTH WHERE GRANTEE='PUBLIC' AND GRANTEETYPE='G'")")
  if is_num "$n" && [ "$n" -eq 0 ]; then
    record PASS "4.1.1" "Keine PUBLIC-Privilegien auf DB-Ebene (RESTRICTIVE)"
  else
    list=$(q "SELECT RTRIM(PRIVILEGE) FROM SYSCAT.DBAUTH WHERE GRANTEE='PUBLIC' AND GRANTEETYPE='G'" | list_inline)
    record FAIL "4.1.1" "$n PUBLIC-Privilegien auf DB-Ebene (z. B. $list) — RESTRICTIVE-DB verwenden oder PUBLIC-Grants entfernen"
  fi

  # 4.1.2 Set Failed Archive Retry Delay (ARCHRETRYDELAY)
  v=$(db_cfg ARCHRETRYDELAY)
  if is_num "$v" && [ "$v" -ge "$EXP_ARCHRETRYDELAY" ]; then
    record PASS "4.1.2" "ARCHRETRYDELAY=$v (>= $EXP_ARCHRETRYDELAY empfohlen)"
  else
    record WARN "4.1.2" "ARCHRETRYDELAY='$v' — Empfehlung lt. Benchmark pruefen (Referenz >= $EXP_ARCHRETRYDELAY)"
  fi

  # 4.1.3 Auto-restart After Abnormal Termination (AUTORESTART)
  v=$(db_cfg AUTORESTART)
  case "$(upper "$v")" in
    ON|YES|TRUE) record PASS "4.1.3" "AUTORESTART=$v (ein)";;
    *)           record FAIL "4.1.3" "AUTORESTART='${v:-nicht gesetzt}' — empfohlen: ON";;
  esac

  # 4.1.4 Disable Database Discovery (DISCOVER_DB)
  check_cfg_eq "4.1.4" DISABLE -- "DISCOVER_DB" "$(db_cfg DISCOVER_DB)" "Database Discovery"

  # 4.1.5-4.1.7 Archivierungs-/Failover-Pfade absichern
  v=$(db_cfg LOGARCHMETH1)
  case "$v" in
    DISK:*) check_no_write "4.1.5" "${v#DISK:}" "Primary Archive Log Location (LOGARCHMETH1)";;
    *)      record INFO "4.1.5" "LOGARCHMETH1='$v' — keine DISK-Pfad-Pruefung moeglich";;
  esac
  v=$(db_cfg LOGARCHMETH2)
  case "$v" in
    DISK:*) check_no_write "4.1.6" "${v#DISK:}" "Secondary Archive Log Location (LOGARCHMETH2)";;
    *)      record INFO "4.1.6" "LOGARCHMETH2='$v' — keine DISK-Pfad-Pruefung moeglich";;
  esac
  check_no_write "4.1.7" "$(db_cfg FAILARCHPATH)" "Tertiary/Failover Archive Path (FAILARCHPATH)" PASS

  # 4.1.8 Mirror Log Location
  check_no_write "4.1.8" "$(db_cfg MIRRORLOGPATH)" "Log Mirror Location (MIRRORLOGPATH)" PASS

  # 4.1.9 Log Overflow Location (Manual)
  check_no_write "4.1.9" "$(db_cfg OVERFLOWLOGPATH)" "Log Overflow Location (OVERFLOWLOGPATH)"

  # 4.1.10 Establish Retention Set Size for Backups (NUM_DB_BACKUPS, Manual)
  record INFO "4.1.10" "NUM_DB_BACKUPS='$(db_cfg NUM_DB_BACKUPS)' — Retention-Set manuell bewerten"

  # 4.1.11 Set Archive Log Failover Retry Limit (NUMARCHRETRY)
  v=$(db_cfg NUMARCHRETRY)
  if is_num "$v" && [ "$v" -ge "$MIN_NUMARCHRETRY" ]; then
    record PASS "4.1.11" "NUMARCHRETRY=$v (>= $MIN_NUMARCHRETRY empfohlen)"
  else
    record WARN "4.1.11" "NUMARCHRETRY='$v' — Empfehlung lt. Benchmark pruefen (Referenz >= $MIN_NUMARCHRETRY)"
  fi

  # 4.1.12 Set Maximum Number of Applications (MAXAPPLS)
  v=$(db_cfg MAXAPPLS)
  if [ "$(upper "$v")" = "AUTOMATIC" ] || [ -z "$v" ]; then
    record WARN "4.1.12" "MAXAPPLS='$v' — endliche Grenze erwegen (Benchmark-Vorgabe pruefen)"
  else
    record PASS "4.1.12" "MAXAPPLS=$v"
  fi

  # 4.1.13/4.1.14 Manuelle Parameter melden
  record INFO "4.1.13" "CONNECT_PROC='$(db_cfg CONNECT_PROC)' — sichere Connect Procedure manuell bewerten"
  record INFO "4.1.14" "EXTBL_LOCATION='$(db_cfg EXTBL_LOCATION)' — sichere Location fuer External Tables manuell bewerten"

  # 4.2/4.3/4.4 Katalog-Views, -Tabellen und Admin- Routinen: keine PUBLIC-Grants
  cat_list=$(q "SELECT RTRIM(TABSCHEMA)||'.'||RTRIM(TABNAME) FROM SYSCAT.TABAUTH \
                WHERE GRANTEE='PUBLIC' AND GRANTEETYPE='G' AND TABSCHEMA IN ($CATALOG_SCHEMAS)")
  n=$(printf '%s' "$cat_list" | grep -c . || true)
  if [ "${n:-0}" -eq 0 ] 2>/dev/null; then
    record PASS "4.2-4.4" "Keine PUBLIC-Privilegien auf Systemkatalog ($CATALOG_SCHEMAS)"
  else
    examples=$(printf '%s\n' "$cat_list" | list_inline)
    record FAIL "4.2-4.4" "$n PUBLIC-Grants auf Systemkatalog, z. B. $examples — PUBLIC-Privilegien entziehen"
  fi

  # 4.4.4-4.4.6 SYSPROC/SYSFUN-Routinen ohne PUBLIC-EXECUTE
  rout_list=$(q "SELECT RTRIM(ROUTINESCHEMA)||'.'||RTRIM(SPECIFICNAME) FROM SYSCAT.ROUTINEAUTH \
                WHERE GRANTEE='PUBLIC' AND GRANTEETYPE='G' AND ROUTINESCHEMA IN ($ROUTINE_SCHEMAS)")
  n=$(printf '%s' "$rout_list" | grep -c . || true)
  if [ "${n:-0}" -eq 0 ] 2>/dev/null; then
    record PASS "4.4.4-6" "Keine PUBLIC-EXECUTE auf $ROUTINE_SCHEMAS-Routinen"
  else
    examples=$(printf '%s\n' "$rout_list" | list_inline)
    record WARN "4.4.4-6" "$n PUBLIC-Grants auf Routinen, z. B. $examples — manuell bewerten"
  fi

  # 4.5.1 Restrict Access to Tablespaces
  n=$(trim "$(q "SELECT COUNT(*) FROM SYSCAT.TBSPACEAUTH WHERE GRANTEE='PUBLIC' AND GRANTEETYPE='G'")")
  if is_num "$n" && [ "$n" -eq 0 ]; then
    record PASS "4.5.1" "Keine PUBLIC-Grants auf Tablespaces"
  else
    record FAIL "4.5.1" "$n PUBLIC-Grants auf Tablespaces — USE-Privilegien fuer PUBLIC entfernen"
  fi

  # 4.5.2/4.5.3 Manuelle Pruefungen
  record INFO "4.5.2" "Ungenutzte Schemas manuell pruefen (z. B. NULLID, alte Anwendungsschemas)"
  record INFO "4.5.3" "System-Tablespaces (SYSCATSPACE, TEMPSPACE1, USERSPACE1) manuell reviewen"

else
  record INFO "4" "Alle 4.x-Pruefungen uebersprungen (keine DB-Verbindung)"
fi

# ================= 5 AUTHENTISIERUNG (5.x) ===================================
sec "5 Authentisierung (5.1-5.11)"

# 5.1 Secure Connection Authentication Type (SRVCON_AUTH)
v=$(dbm_cfg SRVCON_AUTH)
case "$(upper "$v")" in
  CLIENT)        record FAIL "5.1" "SRVCON_AUTH='$v' — CLIENT unzulaessig; ENCRYPT oder staerker setzen";;
  SERVER)        record WARN "5.1" "SRVCON_AUTH='$v' — unverschluesselt; SERVER_ENCRYPT oder staerker erwegen (Benchmark: manuelle Bewertung)";;
  "")            record WARN "5.1" "SRVCON_AUTH nicht ermittelbar";;
  *)             record PASS "5.1" "SRVCON_AUTH='$v'";;
esac

# 5.2 Secure Authentication Type (AUTHENTICATION)
v=$(dbm_cfg AUTHENTICATION)
case "$(upper "$v")" in
  CLIENT)        record FAIL "5.2" "AUTHENTICATION='$v' — CLIENT unzulaessig; SERVER_ENCRYPT oder staerker setzen";;
  SERVER)        record WARN "5.2" "AUTHENTICATION='$v' — unverschluesselt; SERVER_ENCRYPT oder staerker erwegen";;
  "")            record WARN "5.2" "AUTHENTICATION nicht ermittelbar";;
  *)             record PASS "5.2" "AUTHENTICATION='$v'";;
esac

# 5.3 ALTERNATE_AUTH_ENC (Manual)
record INFO "5.3" "ALTERNATE_AUTH_ENC='$(dbm_cfg ALTERNATE_AUTH_ENC)' — Auth-Plugins manuell bewerten"

# 5.4 TRUST_ALLCLNTS
check_cfg_eq "5.4" NO -- "TRUST_ALLCLNTS" "$(dbm_cfg TRUST_ALLCLNTS)" "Trust All Clients"

# 5.5 TRUST_CLNTAUTH (nur relevant bei TRUST_ALLCLNTS=YES)
record INFO "5.5" "TRUST_CLNTAUTH='$(dbm_cfg TRUST_CLNTAUTH)' — nur relevant, wenn TRUST_ALLCLNTS=YES"

# 5.6 FED_NOAUTH
check_cfg_eq "5.6" NO -- "FED_NOAUTH" "$(dbm_cfg FED_NOAUTH)" "Federated No-Auth"

# 5.10 DB2AUTH Registry Variable (Manual): empfohlen TRUE
v=$(db2set_val DB2AUTH)
case "$(upper "$v")" in
  TRUE|YES|ON) record PASS "5.10" "DB2AUTH='$v' (empfohlen)";;
  *)           record FAIL "5.10" "DB2AUTH='${v:-nicht gesetzt}' — empfohlen: TRUE (db2set DB2AUTH=TRUE)";;
esac

# 5.11 DB2CHGPWD_EEE (Manual)
record INFO "5.11" "DB2CHGPWD_EEE='$(db2set_val DB2CHGPWD_EEE)' — Empfehlung lt. Benchmark pruefen"

# ================= 6 BERECHTIGUNGEN (6.x) ====================================
sec "6 Berechtigungen und Rollen (6.1-6.2)"

# 6.1.1-6.1.4 Instanz-Admin-Gruppen (Manual): Gruppen + Mitglieder melden
for spec in "6.1.1 SYSADM_GROUP SYSADM" "6.1.2 SYSCTRL_GROUP SYSCTRL" \
            "6.1.3 SYSMAINT_GROUP SYSMAINT" "6.1.4 SYSMON_GROUP SYSMON"; do
  set -- $spec; id="$1"; param="$2"; role="$3"
  grp=$(dbm_cfg "$param")
  members=$(getent group "$grp" 2>/dev/null | awk -F: '{print $4}')
  record INFO "$id" "$role-Gruppe: '$grp' — Mitglieder: ${members:-<leer/nicht ermittelbar>} (manuell auf Notwendigkeit pruefen)"
done

if [ "$DB_LEVEL" -eq 1 ]; then
  # 6.1.5-6.1.20 DB-Autoritaeten (Manual): Inhaber melden
  dbadm_list=$(q "SELECT RTRIM(GRANTEE)||'('||RTRIM(GRANTEETYPE)||')' FROM SYSCAT.DBADM")
  if [ -n "$dbadm_list" ]; then
    examples=$(printf '%s\n' "$dbadm_list" | list_inline)
    record INFO "6.1.5-20" "DBADM/DB-Autoritaeten laut SYSCAT.DBADM: $examples (manuell reviewen)"
  else
    record INFO "6.1.5-20" "Keine Eintraege in SYSCAT.DBADM ermittelbar (SECADM/DBADM manuell pruefen)"
  fi

  # 6.2.5 Rollen fuer PUBLIC
  n=$(trim "$(q "SELECT COUNT(*) FROM SYSCAT.ROLEAUTH WHERE GRANTEE='PUBLIC' AND GRANTEETYPE='G'")")
  if is_num "$n" && [ "$n" -gt 0 ]; then
    record WARN "6.2.5" "$n an PUBLIC vergebene Rollen — Review erforderlich"
  else
    record PASS "6.2.5" "Keine Rollen an PUBLIC vergeben"
  fi
else
  record INFO "6.2" "Datenbank-Rollen-Pruefungen uebersprungen (keine DB-Verbindung)"
fi

# ================= 7 AUDITING (7.1) ==========================================
sec "7 Auditing (7.1)"

# 7.1.1 Audit Buffer: Ist-Wert melden (Titel im Benchmark 'Disable the Audit Buffer')
record INFO "7.1.1" "AUDIT_BUF_SZ='$(dbm_cfg AUDIT_BUF_SZ)' — Referenzwert lt. Benchmark-PDF (Abschn. 7.1.1) abgleichen"

# 7.1.2 Disable Limited Audit of Applications (DB2_LIMIT_AUDIT_APPS)
check_reg_unset "7.1.2" "DB2_LIMIT_AUDIT_APPS" "Limitierte Anwendungs-Auditierung" WARN

if [ "$DB_LEVEL" -eq 1 ]; then
  # 7.1.3 Ensure Audit Policies are Enabled Within the Database (Manual)
  n=$(trim "$(q "SELECT COUNT(*) FROM SYSCAT.AUDITUSE")")
  if is_num "$n" && [ "$n" -gt 0 ]; then
    record PASS "7.1.3" "$n aktive Audit-Policies laut SYSCAT.AUDITUSE"
  else
    record WARN "7.1.3" "Keine aktiven Audit-Policies — Audit-Policies anlegen (Benchmark 7.1.3)"
  fi
else
  record INFO "7.1.3" "Uebersprungen (keine DB-Verbindung)"
fi

# 7.1.4 Ensure Audit is Enabled Within the Instance (Automated, best effort)
DB2AUDIT_BIN=""
for c in "$(command -v db2audit 2>/dev/null)" "$HOME/sqllib/bin/db2audit" "$HOME/sqllib/adm/db2audit"; do
  [ -n "$c" ] && [ -x "$c" ] && DB2AUDIT_BIN="$c" && break
done
if [ -n "$DB2AUDIT_BIN" ]; then
  desc=$("$DB2AUDIT_BIN" describe 2>/dev/null || true)
  if printf '%s' "$desc" | grep -qi 'enabled'; then
    record PASS "7.1.4" "db2audit: Auditing offenbar aktiviert"
  else
    record WARN "7.1.4" "db2audit: Aktivierung unklar — Ausgabe von 'db2audit describe' manuell pruefen"
  fi
else
  record WARN "7.1.4" "db2audit-Binaerdatei nicht gefunden — Instanz-Auditing manuell pruefen"
fi

# ================= 8 VERSCHLUESSELUNG (8.1/8.2) ==============================
sec "8 Verschluesselung (8.1 in Motion, 8.2 at Rest)"

# 8.1.1 Server-seitiger Key Store fuer TLS (SSL_SVR_KEYDB)
v=$(dbm_cfg SSL_SVR_KEYDB)
if [ -n "$v" ] && [ -f "$v" ]; then
  record PASS "8.1.1" "SSL_SVR_KEYDB='$v' (Datei vorhanden)"
elif [ -n "$v" ]; then
  record FAIL "8.1.1" "SSL_SVR_KEYDB='$v' — Datei existiert nicht"
else
  record FAIL "8.1.1" "SSL_SVR_KEYDB nicht gesetzt — Server-Keystore konfigurieren"
fi

# 8.1.2 Server-seitige Stash File (SSL_SVR_STASH)
v=$(dbm_cfg SSL_SVR_STASH)
if [ -n "$v" ] && [ -f "$v" ]; then
  record PASS "8.1.2" "SSL_SVR_STASH='$v' (Datei vorhanden)"
elif [ -n "$v" ]; then
  record FAIL "8.1.2" "SSL_SVR_STASH='$v' — Datei existiert nicht"
else
  record FAIL "8.1.2" "SSL_SVR_STASH nicht gesetzt — Stash File konfigurieren"
fi

# 8.1.3 Endpoint Certificate (SSL_SVR_LABEL)
v=$(dbm_cfg SSL_SVR_LABEL)
if [ -n "$v" ]; then record PASS "8.1.3" "SSL_SVR_LABEL='$v'";
else record WARN "8.1.3" "SSL_SVR_LABEL nicht gesetzt — Zertifikat-Label konfigurieren"; fi

# 8.1.4 Service Name for TLS (SSL_SVCENAME)
v=$(dbm_cfg SSL_SVCENAME)
if [ -n "$v" ]; then record PASS "8.1.4" "SSL_SVCENAME='$v'";
else record FAIL "8.1.4" "SSL_SVCENAME nicht gesetzt — TLS-Listener konfigurieren"; fi

# 8.1.5 Secure TLS Version (SSL_VERSIONS)
v=$(upper "$(dbm_cfg SSL_VERSIONS)")
if printf '%s' "$v" | grep -qE 'TLS10|TLS11'; then
  record FAIL "8.1.5" "SSL_VERSIONS='$v' — TLS 1.0/1.1 entfernen (nur TLSv12/TLSv13)"
elif printf '%s' "$v" | grep -qE 'TLS12|TLS13'; then
  record PASS "8.1.5" "SSL_VERSIONS='$v' (TLS 1.2+)"
else
  record WARN "8.1.5" "SSL_VERSIONS='${v:-nicht gesetzt}' — Standardwert gegen Benchmark-PDF abgleichen"
fi

# 8.1.6 Secure TLS Cipher Suites (Manual)
record INFO "8.1.6" "SSL_CIPHERSPECS='$(dbm_cfg SSL_CIPHERSPECS)' — Cipher-Suites manuell gegen Benchmark bewerten"

# 8.1.7 Unset the Service Name for Plaintext Communication (SVCENAME)
v=$(dbm_cfg SVCENAME)
if [ -z "$v" ]; then
  record PASS "8.1.7" "SVCENAME nicht gesetzt — kein Plaintext-TCP-Listener"
else
  record WARN "8.1.7" "SVCENAME='$v' — Plaintext-Listener aktiv; Abschaltung erwegen, sofern nicht erforderlich"
fi

# 8.1.8/8.1.9 Client-seitige Key Stores (Manual)
record INFO "8.1.8" "SSL_CLNT_KEYDB='$(dbm_cfg SSL_CLNT_KEYDB)' — manuell bewerten"
record INFO "8.1.9" "SSL_CLNT_STASH='$(dbm_cfg SSL_CLNT_STASH)' — manuell bewerten"

# 8.1.10 HADR-TLS (Manual)
record INFO "8.1.10" "HADR-Verschluesselung zwischen Primary/Standby manuell pruefen"

# 8.1.11 Remote TLS Connections (DB2COMM)
v=$(upper "$(db2set_val DB2COMM)")
if printf '%s' "$v" | grep -q 'SSL'; then
  record PASS "8.1.11" "DB2COMM='$v' (SSL aktiviert)"
else
  record WARN "8.1.11" "DB2COMM='${v:-nicht gesetzt}' — SSL in DB2COMM ergaenzen (z. B. TCPIP,SSL)"
fi

# 8.2 Verschluesselung at rest (Manual-Hinweise)
record INFO "8.2.1" "Native Encryption der Datenbank manuell pruefen (ENC...-Parameter / db2pd -enc)"
record INFO "8.2.3" "Konfigurationsdatei und Stash-File der Native Encryption manuell pruefen (Instanzowner, 600)"

# ============================== ZUSAMMENFASSUNG ==============================
sec "Zusammenfassung"
total=$(( PASS_CNT + FAIL_CNT ))
if [ "$total" -gt 0 ]; then
  score=$(( PASS_CNT * 100 / total ))
else
  score=0
fi
echo "PASS: $PASS_CNT   FAIL: $FAIL_CNT   WARN: $WARN_CNT   INFO: $INFO_CNT"
echo "Konformitaets-Score (PASS/(PASS+FAIL)): ${score}%"
echo "Referenz: CIS IBM Db2 11 Benchmark v1.2.0 / CIS IBM Db2 12.1 Benchmark v1.0.0"
echo "WARN/INFO-Befunde sind manuell bzw. gegen das offizielle CIS-PDF zu bewerten."

db2 connect reset >/dev/null 2>&1 || true
[ "$FAIL_CNT" -eq 0 ] && exit 0 || exit 1
