# FALCON INTEGRITY FIX — PIF Preferred Logic (من Specter، مُكيَّف)
# ==============================================================================
# يختار بصمة Canary بناءً على "preferred" order (جهازك → bluejay → oriole → random)
# بدلاً من random صرف — بصمة أكثر استقراراً.
#
# التكامل في falcon_update_pif.sh:
#   - استبدل كتلة اختيار الجهاز (lines 220-242) بـ pif_apply_preferred
# ==============================================================================

# --- PIF Canary devices (preferred order) ---
PIF_CANARY_DEVICES="Pixel 6|oriole_beta
Pixel 6 Pro|raven_beta
Pixel 6a|bluejay_beta
Pixel 7|panther_beta
Pixel 7 Pro|cheetah_beta
Pixel 7a|lynx_beta
Pixel Fold|felix_beta
Pixel Tablet|tangorpro_beta
Pixel 8|shiba_beta
Pixel 8 Pro|husky_beta
Pixel 8a|akita_beta
Pixel 9|tokay_beta
Pixel 9 Pro|caiman_beta
Pixel 9 Pro XL|komodo_beta
Pixel 9 Pro Fold|comet_beta
Pixel 9a|tegu_beta"

# --- cfg_get (ملف-based) ---
cfg_get() {
  _cg_key="$1" _cg_default="$2"
  _cg_val=""
  if [ -f "/data/adb/falcon/config/val/$_cg_key.val" ]; then
    IFS= read -r _cg_val < "/data/adb/falcon/config/val/$_cg_key.val" 2>/dev/null || true
  fi
  printf '%s' "${_cg_val:-$_cg_default}"
  unset _cg_key _cg_default _cg_val
}

cfg_set() {
  mkdir -p "/data/adb/falcon/config/val" 2>/dev/null
  printf '%s' "$2" > "/data/adb/falcon/config/val/$1.val" 2>/dev/null
}

# --- اختيار جهاز preferred (من Specter pif_choose_preferred) ---
# $1 = preferred lines "MODEL|PRODUCT"
# Prints one surviving line; return 1 if none remain.
pif_choose_preferred() {
  _cpp_prefs="$1"
  _cpp_ok=""
  _cpp_n=0
  while IFS= read -r _cpp_line || [ -n "$_cpp_line" ]; do
    [ -n "$_cpp_line" ] || continue
    case "$_cpp_line" in *'|'*) ;; *) continue ;; esac
    _cpp_product="${_cpp_line##*\|}"
    [ -n "$_cpp_product" ] || continue
    _cpp_ok="${_cpp_ok}${_cpp_line}
"
    _cpp_n=$((_cpp_n + 1))
  done <<EOF
$_cpp_prefs
EOF
  [ "$_cpp_n" -gt 0 ] || { unset _cpp_prefs _cpp_ok _cpp_n _cpp_product _cpp_pick _cpp_line; return 1; }
  _cpp_seed="${RANDOM:-$$}"
  case "$_cpp_seed" in *[!0-9]*) _cpp_seed="$$" ;; esac
  _cpp_pick=$((_cpp_seed % _cpp_n))
  _cpp_n=0
  while IFS= read -r _cpp_line || [ -n "$_cpp_line" ]; do
    [ -n "$_cpp_line" ] || continue
    if [ "$_cpp_n" -eq "$_cpp_pick" ]; then
      printf '%s\n' "$_cpp_line"
      unset _cpp_prefs _cpp_ok _cpp_n _cpp_product _cpp_pick _cpp_line
      return 0
    fi
    _cpp_n=$((_cpp_n + 1))
  done <<EOF
$_cpp_ok
EOF
  unset _cpp_prefs _cpp_ok _cpp_n _cpp_product _cpp_pick _cpp_line
  return 1
}

# --- فلترة blacklist ---
pif_filter_blacklist() {
  _pfb_list="$1"
  _pfb_bl="$2"
  [ -n "$_pfb_bl" ] || { printf '%s\n' "$_pfb_list"; unset _pfb_list _pfb_bl; return 0; }
  while IFS= read -r _pfb_line || [ -n "$_pfb_line" ]; do
    [ -n "$_pfb_line" ] || continue
    _pfb_prod="${_pfb_line##*\|}"
    [ -n "$_pfb_prod" ] || continue
    case "$_pfb_bl" in *"$_pfb_prod"*) continue ;; esac
    printf '%s\n' "$_pfb_line"
  done <<EOF
$_pfb_list
EOF
  unset _pfb_list _pfb_bl _pfb_line _pfb_prod
}

pif_choose_random_canary() {
  _pcrc_bl="$1"
  _pcrc_pool=$(pif_filter_blacklist "$PIF_CANARY_DEVICES" "$_pcrc_bl")
  if [ -z "$_pcrc_pool" ]; then
    _pcrc_pool="$PIF_CANARY_DEVICES"
  fi
  pif_choose_preferred "$_pcrc_pool"
  unset _pcrc_bl _pcrc_pool
}

# --- اختيار جهاز preferred (main entry) ---
# Returns: "MODEL|PRODUCT" on stdout, exit 0 on success
pif_select_device() {
  _prefs=$(cfg_get pif_preferred_devices '')
  if [ -z "$_prefs" ]; then
    _legacy_p=$(cfg_get pif_preferred_product '')
    _legacy_m=$(cfg_get pif_preferred_model '')
    [ -n "$_legacy_p" ] && _prefs="${_legacy_m}|${_legacy_p}"
    unset _legacy_p _legacy_m
  fi

  _choice=""
  if [ -n "$_prefs" ]; then
    _choice=$(pif_choose_preferred "$_prefs") || _choice=""
  fi

  if [ -z "$_choice" ]; then
    _bl=$(cfg_get pif_blacklist '')
    if [ -n "$_bl" ]; then
      _choice=$(pif_choose_random_canary "$_bl") || _choice=""
    fi
    unset _bl
  fi

  [ -n "$_choice" ] || return 1
  printf '%s\n' "$_choice"
  unset _prefs _choice
  return 0
}