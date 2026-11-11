#!/system/bin/sh

# ==============================================================================
# FALCON TRICKY - ملحق وحدة مرئية في مدير الروت
# المطور: ABUFARID | تليجرام: @FALCON_KERNEL
#
# ⚠️ هذا الملحق لا يحمل نسخة ثانية من محرك Tricky Store:
#    المحرك مملوك للإضافة الأم (falcon_integrity_fix) ويُشغَّل منها فقط.
#    تشغيل المحرك مرتين يحقن keystore2 مرتين ويجمّد الجهاز بالكامل،
#    لذلك هذا الملحق لا يشغّل المحرك أبداً.
#
# غرضه:
#    1) الظهور في قائمة مدير الروت باسم FALCON TRICKY.
#    2) ضمان الرابط المزدوج الصارم: حذف أحدهما يحذف الآخر إجبارياً.
#    3) (v3.22.9) تحديث وصف الوحدة دورياً: ⚙️ المحرك + حماية Google X/3
#       + 🔑 حالة الكيبوكس — نفس بيانات FALCON TRICKY WebUI (بلا 👤 Online).
# ==============================================================================

MODDIR="${0%/*}"

# (v3.29) حُذف منطق الإزالة الذاتية (touch remove) الذي كان يُفعّل تنبيه
# قاعدة الأمان في KernelSU Next. الوحدة تُدار من مدير الروت مباشرة.

# 3) (v3.22.9) تحديث وصف FALCON TRICKY في مدير الروت — نفس بيانات الواجهة:
#    ⚙️ حالة المحرك | حماية Google X/3 | 🔑 حالة الكيبوكس (بلا 👤 Online)
TARGET_TXT="/data/adb/tricky_store/target.txt"
PROP="$MODDIR/module.prop"
while true; do
    if pidof TrickyStoreOSS >/dev/null 2>&1; then
        ENGINE_TAG="⚙️ Engine: Running"
    else
        ENGINE_TAG="⚙️ Engine: Stopped"
    fi

    GOOGLE_PROT=0
    for _pkg in com.google.android.gms com.google.android.gms.unstable com.android.vending; do
        grep -qx "$_pkg" "$TARGET_TXT" 2>/dev/null && GOOGLE_PROT=$((GOOGLE_PROT + 1))
    done

    KB_TAG=""
    _kba=""
    _kbe=""
    if [ -s /data/adb/falcon_keysync/kb_alert ]; then
        _kba=$(head -n 1 /data/adb/falcon_keysync/kb_alert 2>/dev/null | cut -d'|' -f1 | tr -d ' \t\r\n')
        _kbe=$(head -n 1 /data/adb/falcon_keysync/kb_alert 2>/dev/null | cut -d'|' -f2 | tr -d ' \t\r\n')
    fi
    # (v3.29) احتياطي: تاريخ الانتهاء المحفوظ مؤقتاً (إن كان الحقل الثاني غير معروف)
    case "$_kbe" in
        ''|unknown|UNKNOWN)
            if [ -s /data/adb/falcon_keysync/kb_expiry_cache ]; then
                _kbe=$(head -n 1 /data/adb/falcon_keysync/kb_expiry_cache 2>/dev/null | cut -d'|' -f1 | tr -d ' \t\r\n')
            fi
            ;;
    esac
    # (v3.29) احتياطي أخير: التاريخ المكتوب وقت التثبيت داخل مجلد الوحدة
    case "$_kbe" in
        ''|unknown|UNKNOWN)
            if [ -s "$MODDIR/kb_expiry.txt" ]; then
                _kbe=$(head -n 1 "$MODDIR/kb_expiry.txt" 2>/dev/null | tr -d ' \t\r\n')
            fi
            ;;
    esac
    case "$_kbe" in ''|unknown|UNKNOWN) _kbe="" ;; esac

    if [ -n "$_kbe" ]; then __KE=" (exp: $_kbe)"; else __KE=""; fi
    case "$_kba" in
        OK*)       KB_TAG="🔑 OK${__KE}" ;;
        REVOKED*)  KB_TAG="🔑 REVOKED${__KE}" ;;
        EXPIRED*)  KB_TAG="🔑 EXPIRED${__KE}" ;;
        EXPIRING*) KB_TAG="🔑 EXPIRING${__KE}" ;;
        FAIL*)     KB_TAG="🔑 MISSING${__KE}" ;;
        *)
            # لا يوجد ملف تنبيه نشط، لكن التاريخ معروف ⇒ اعرضه بجانب حالة سليمة
            if [ -n "$_kbe" ]; then KB_TAG="🔑 OK${__KE}"; fi
            ;;
    esac
    if [ -z "$KB_TAG" ]; then
        if [ -s /data/adb/falcon_keysync/kb_state ]; then
            KB_ST=$(head -n 1 /data/adb/falcon_keysync/kb_state 2>/dev/null | tr -d ' \t\r\n')
            case "$KB_ST" in
                OK*)       KB_TAG="🔑 OK${__KE}" ;;
                REVOKED*)  KB_TAG="🔑 REVOKED${__KE}" ;;
            esac
        fi
    fi
    if [ -z "$KB_TAG" ]; then
        if [ -s /data/adb/tricky_store/keybox.xml ] && grep -q "<AndroidAttestation" /data/adb/tricky_store/keybox.xml 2>/dev/null; then
            KB_TAG="🔑 Attached"
        else
            KB_TAG="🔑 Missing"
        fi
    fi

    NEW_DESC="$ENGINE_TAG | Google: $GOOGLE_PROT/3 | $KB_TAG"

    if [ -f "$PROP" ]; then
        CUR=$(grep '^description=' "$PROP" 2>/dev/null | head -n 1)
        if [ "$CUR" != "description=$NEW_DESC" ]; then
            sed -i "s@^description=.*@description=$NEW_DESC@" "$PROP" 2>/dev/null
        fi
    fi

    sleep 4
done

exit 0
