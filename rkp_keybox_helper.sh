#!/system/bin/sh
# ==============================================================================
# FALCON INTEGRITY FIX — مساعد استخراج كيبوكس RKP من جهازك (v3.33)
# المطور: ABUFARID | Telegram: @FALCON_KERNEL
#
# يولّد كيبوكسًا خاصًا بالجهاز عبر TeeForge-CD (Device RKP Issuer)، ثم يتحقق
# منه مقابل قائمة إبطال Google قبل تثبيته في منفذ FALCON.
#
# الاستخدام (من root shell أو KernelSU/APatch shell):
#   sh /data/adb/modules/falcon_integrity_fix/rkp_keybox_helper.sh --check
#   sh /data/adb/modules/falcon_integrity_fix/rkp_keybox_helper.sh --all
#   sh /data/adb/modules/falcon_integrity_fix/rkp_keybox_helper.sh --export
#
# --check  : فحص توافق الجهاز فقط (لا يرسل أي طلب للشبكة)
# --issue  : طلب إصدار كيبوكس RKP من Google عبر TeeForge-CD
# --all    : فحص + إصدار + تحقق + تثبيت
# --export : طباعة الكيبوكس بصيغة base64 لإرساله للمطور وإدماجه في الحزمة
# ==============================================================================

MODDIR="${0%/*}"
[ -n "$MODDIR" ] && [ -d "$MODDIR" ] || MODDIR="/data/adb/modules/falcon_integrity_fix"

TEEFORGE="/data/adb/modules/teeforge_cd/runtime/teeforge"
RKP_DIR="/data/adb/teeforge/RKP"
RKP_KB="$RKP_DIR/keybox.xml"
TARGET="/data/adb/tricky_store/keybox.xml"
SLOT="/data/adb/falcon/.token_cache"

say() { printf '[FALCON-RKP] %s\n' "$1"; }
die() { printf '[FALCON-RKP] ✖ %s\n' "$1"; exit 1; }

check_root() {
    [ "$(id -u)" = "0" ] || die "يجب التشغيل بصلاحية root"
}

check_tee() {
    check_root
    if [ ! -x "$TEEFORGE" ]; then
        die "TeeForge-CD غير مثبت. ثبّت الموديول من:
https://github.com/mcxiaochenn/TeeForge-CD/releases/latest
ثم أعد المحاولة."
    fi
    say "جاري فحص توافق الجهاز (بدون إنترنت)…"
    "$TEEFORGE" --rkp-status || die "فحص التوافق فشل — الجهاز/البرنامج الثابت غير مدعوم"
    say "اكتمل فحص التوافق."
}

issue_kb() {
    check_tee
    say "جاري طلب كيبوكس RKP من جهازك (قد يستغرق دقائق)…"
    "$TEEFORGE" --rkp-issue || die "فشل الإصدار — راجع /data/adb/teeforge/logs/"
    [ -s "$RKP_KB" ] || die "لم يُنتج الملف: $RKP_KB"
    say "نُتج الكيبوكس: $RKP_KB ($(wc -c < "$RKP_KB" | tr -d ' ') بايت)"
}

verify_kb() {
    [ -s "$RKP_KB" ] || die "لا يوجد كيبوكس للتحقق منه"
    say "تحديث قائمة إبطال Google…"
    sh "$MODDIR/kb_sync.sh" --check >/dev/null 2>&1
    say "التحقق من البنية والقائمة الرمادية…"
    V=$(sh "$MODDIR/kb_sync.sh" --verify="$RKP_KB" 2>&1 | tail -n 1)
    say "النتيجة: $V"
    case "$V" in
        VERIFY=OK*) return 0 ;;
        *) die "الكيبوكس مرفوض: $V" ;;
    esac
}

install_kb() {
    verify_kb || return 1
    say "تثبيت كيبوكس RKP في منفذ FALCON…"
    mkdir -p /data/adb/falcon /data/adb/tricky_store 2>/dev/null
    [ -s "$SLOT" ] && cp -f "$SLOT" "/data/adb/falcon/.token_cache.bak-rkp-$(date '+%Y%m%d-%H%M%S')" 2>/dev/null
    cp -f "$RKP_KB" "$SLOT" 2>/dev/null || die "فشل الكتابة في المنفذ"
    chmod 600 "$SLOT" 2>/dev/null
    chown root:root "$SLOT" 2>/dev/null
    cp -f "$RKP_KB" "$TARGET" 2>/dev/null
    chmod 644 "$TARGET" 2>/dev/null
    chown root:root "$TARGET" 2>/dev/null
    printf 'custom\n' > /data/adb/falcon/.token_source 2>/dev/null
    chmod 600 /data/adb/falcon/.token_source 2>/dev/null
    say "✅ تم التثبيت. أعد تشغيل خدمة TrickyStore أو أعد الإقلاع."
}

export_kb() {
    [ -s "$RKP_KB" ] || die "لا يوجد كيبوكس — شغّل --all أولًا"
    verify_kb || return 1
    say "انسخ السطر التالي وأرسله للمطور لإدماجه في نسخة الاختبار:"
    printf 'FALCON_RKP_KB64='; base64 -w0 "$RKP_KB" 2>/dev/null || base64 "$RKP_KB" | tr -d '\n'
    printf '\n'
}

case "${1:---all}" in
    --check)  check_tee ;;
    --issue)  issue_kb ;;
    --verify) verify_kb ;;
    --install) install_kb ;;
    --all)    issue_kb; install_kb ;;
    --export) export_kb ;;
    *) die "خيار غير معروف: $1" ;;
esac
