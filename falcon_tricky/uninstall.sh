#!/system/bin/sh

# ==============================================================================
# FALCON TRICKY - الرابط المزدوج (الاتجاه الثاني)
# (v3.15) حذف هذا الملحق من مدير الروت يحذف الإضافة الأم FALCON INTEGRITY FIX
#          فوراً ونهائياً مع كل تنظيفاتها — لا انتظار إعادة تشغيل.
#
# التسلسل:
#   1) تشغيل سكربت تنظيف الإضافة الأم كاملاً (resetprop + إيقاف المحرك + السجلات)
#      مع علم FALCON_FROM_COMPANION=1 حتى لا يحذف الأم مجلدَنا ونحن نعمل داخله
#   2) حذف مجلد الإضافة الأم حذفاً حقيقياً من المسارين
#   3) تنظيف بيانات الملحق (أرشيف أيقونات التطبيقات)
#
# ⚠️ لا يوجد استدعاء متبادل (recursion): سكربت الإضافة الأم لا يستدعي هذا
#    السكربت بل يحذف المجلد فقط، لذلك ينتهي التنظيف بلا حلقة لا نهائية.
# ⛔ لا نحذف /data/adb/tricky_store (كيبوكس المستخدم + target.txt).
# ==============================================================================

MAIN_ID="falcon_integrity_fix"

# 1) تنظيف الإضافة الأم من داخل نفسها (قبل حذفها) — محصّن ضد أي فشل
for B in /data/adb/modules /data/adb/modules_update; do
    if [ -d "$B/$MAIN_ID" ] && [ -f "$B/$MAIN_ID/uninstall.sh" ]; then
        FALCON_FROM_COMPANION=1 sh "$B/$MAIN_ID/uninstall.sh" >/dev/null 2>&1 || true
    fi
done

# 2) (v3.47) إزالة مزدوجة: حذف الوحدة الأم فعلياً (بلا علامة remove،
#    تفادياً لتنبيه قاعدة الأمان في KernelSU Next).
if [ "${FALCON_FROM_MAIN:-0}" != "1" ]; then
    for B in /data/adb/modules /data/adb/modules_update; do
        [ -d "$B/$MAIN_ID" ] && rm -rf "$B/$MAIN_ID" 2>/dev/null
    done
fi

# 3) إلغاء تثبيت تطبيق FALCON TRICKY (APK)
pm uninstall com.falcon.tricky >/dev/null 2>&1 || true

# 4) بيانات الملحق (أرشيف الأيقونات المستخرجة من تطبيقات الجهاز)
rm -rf /data/adb/falcon_icons 2>/dev/null

exit 0
