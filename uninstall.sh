#!/system/bin/sh

# ==============================================================================
# FALCON INTEGRITY FIX - سكربت إزالة التثبيت والتنظيف
# المطور: ABUFARID
# ==============================================================================

# إزالة خاصية GMS من الذاكرة الحالية
if command -v resetprop >/dev/null 2>&1; then
    resetprop --delete persist.sys.spoof.gms 2>/dev/null
fi

# حذف ملف الخاصية الدائمة إن كان موجودًا
rm -f "/data/property/persist.sys.spoof.gms" 2>/dev/null

# --- (v3.19) إرجاع خصائص تعطيل تزييف الروم التي كتبناها (فقط ما زال بقيمتنا) ---
# احتراماً لأي قيمة وضعها المستخدم أو وحدة أخرى: نُعيد فقط ما كتبناه نحن.
if command -v resetprop >/dev/null 2>&1; then
    revert_prop() { [ "$(resetprop "$1" 2>/dev/null)" = "$2" ] && resetprop -p --delete "$1" 2>/dev/null; }
    revert_prop persist.sys.pihooks.disable.gms_props true
    revert_prop persist.sys.pihooks.disable.gms_key_attestation_block true
    revert_prop persist.sys.entryhooks_enabled false
    revert_prop persist.sys.pixelprops.google false
    revert_prop persist.sys.pixelprops.vending false
    revert_prop persist.sys.pihooks.enabled_features 0
    revert_prop persist.sys.pihooks.disable 1
    revert_prop persist.sys.kihooks.disable 1
    revert_prop persist.sys.pixelprops.pi false
    revert_prop persist.sys.pixelprops.gapps false
    revert_prop persist.sys.pixelprops.gms false
    # الخانتان الفارغتان (أنشأناهما فارغتين فقط إن لم تكونا موجودتين أصلاً)
    for EP in persist.sys.pihooks.first_api_level persist.sys.pihooks.security_patch; do
        [ -z "$(resetprop "$EP" 2>/dev/null)" ] && resetprop -p --delete "$EP" 2>/dev/null
    done
fi

# (v3.29) لا نحذف ملفات السجل يدوياً — تزول مع مجلد الوحدة عند إزالتها.
# (كانت هنا أوامر rm -f على مسارات /data/adb/modules/* وهي تُفعّل تنبيه
#  "تعطيل وحدات أخرى" في KernelSU Next.)

# تنظيف ملفات البصمة التي نشرناها في مسار المحرك (فقط إن كنا نحن من أنشأها)
# ✅ مشروط بعدم وجود module.prop ⇒ المجلد مرآة أنشأناها، وليس وحدة مستقلة.
PIF_MIRROR_DIR="/data/adb/modules/playintegrityfix"
if [ -d "$PIF_MIRROR_DIR" ] && [ ! -f "$PIF_MIRROR_DIR/module.prop" ]; then
    for _pf in custom.pif.json pif.json custom.pif.prop pif.prop classes.dex; do
        [ -e "$PIF_MIRROR_DIR/$_pf" ] && rm -f "$PIF_MIRROR_DIR/$_pf" 2>/dev/null
    done
    rmdir "$PIF_MIRROR_DIR" 2>/dev/null
fi
rm -f /data/adb/pif.json /data/adb/pif.prop 2>/dev/null

# --- إيقاف محرك التعتيد المفتوح المصدر (Tricky Store OSS) ---
for P in TrickyStoreOSS TrickyStore; do
    for PID in $(pidof "$P" 2>/dev/null); do
        kill -9 "$PID" 2>/dev/null
    done
done
pkill -f "io.github.beakthoven.TrickyStoreOSS" 2>/dev/null || true

# --- (v3.29) لا نُعدّل علامات أي وحدة أخرى عند الإزالة (قراءة فقط / لا لمس) ---
# النسخ السابقة كانت تزيل علامات remove/disable من وحدات التعتيد الأخرى،
# وهذا يُصنَّف "تعطيل وحدات أخرى" في فحص أمان KernelSU Next.
# الآن: لا نمس أي مديول غير مديولاتنا.

# --- (v3.29) لا نضع أي علامة remove على أي مجلد وحدة (لا ours ولا غيرنا) ---
# هذا هو الكود الذي كان يُفعّل تنبيه قاعدة الأمان في KernelSU Next.
# إزالة FALCON TRICKY (إن وُجدت) تتم من مدير الروت مباشرة.

# بيانات الملحق الخاصة (أرشيف أيقونات التطبيقات المستخرجة من الجهاز)
rm -rf /data/adb/falcon_icons 2>/dev/null

# --- تنظيف ملفات حالة المحرك ---
# ⛔ لا نحذف /data/adb/tricky_store إطلاقاً: قد يحتوي كيبوكس/إعدادات شخصية
#    للمستخدم من وحدة TrickyStore المستقلة. نُبقيها كما هي.
rm -f /data/adb/tricky_store/*.bak /data/adb/tricky_store/*.falcon_merge 2>/dev/null
rm -f /data/adb/falcon_daemon.log /data/adb/falcon_pif.log /data/adb/falcon_rkp_fix.log 2>/dev/null

# --- (v3.19) تنظيف ملفات الحالة والمؤشرات المؤقتة (يبقى كيبوكس المستخدم والهوية المحفوظة) ---
rm -f /data/adb/falcon_online_count /data/adb/falcon_known_packages.txt \
      /data/adb/falcon_current_packages.txt /data/adb/falcon_device_id \
      /data/adb/falcon_conflict.log /data/adb/falcon/auto_hide.log \
      /data/adb/falcon/vbmeta_hash 2>/dev/null
rm -rf /data/adb/falcon_keysync /data/adb/falcon/crl 2>/dev/null

exit 0