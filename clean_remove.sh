#!/system/bin/sh
# ==============================================================================
# FALCON INTEGRITY FIX — تنظيف وإزالة كاملة (v3.36)
# يعمل من زر الواجهة أو من الـ shell: sh clean_remove.sh
# المطور: ABUFARID | Telegram: @FALCON_KERNEL
# ==============================================================================

say() { printf '[FALCON-CLEAN] %s\n' "$1"; }

# البحث عن busybox/toybox متاح لإزالة أي قفل chattr قديم
BB=""
for P in \
    /data/adb/modules/falcon_integrity_fix/busybox \
    /data/adb/modules_update/falcon_integrity_fix/busybox \
    /data/adb/ksu/bin/busybox \
    /data/adb/magisk/busybox \
    /data/adb/ap/bin/busybox \
    /system/bin/toybox; do
    [ -x "$P" ] && { BB="$P"; break; }
done

if [ -n "$BB" ]; then
    say "إزالة أقفال الملفات..."
    "$BB" find /data/adb/modules /data/adb/modules_update -type f -exec "$BB" chattr -i {} \; 2>/dev/null
    for M in falcon_integrity_fix falcon_tricky; do
        for B in /data/adb/modules /data/adb/modules_update; do
            [ -d "$B/$M" ] && "$BB" find "$B/$M" -type f -exec "$BB" chattr -i {} \; 2>/dev/null
        done
    done
else
    say "لم يُعثر على busybox — ستُجرّب الإزالة المباشرة"
fi

# تعليم الوحدتين للحذف عند الإقلاع
for M in falcon_integrity_fix falcon_tricky; do
    for B in /data/adb/modules /data/adb/modules_update; do
        if [ -d "$B/$M" ]; then
            : > "$B/$M/remove" 2>/dev/null
            say "marked: $B/$M"
        fi
    done
done

# تنظيف مجلدات الحالة الخاصة بنا فقط (لا نلمس كيبوكس المستخدم)
rm -rf /data/adb/falcon_keysync 2>/dev/null
rm -rf /data/adb/falcon 2>/dev/null
rm -f /data/adb/modules/falcon_integrity_fix/*.log 2>/dev/null
rm -f /data/adb/modules/falcon_tricky/*.log 2>/dev/null

# إعادة تشغيل服务等
for SVC in com.google.android.gms.unstable com.google.android.vending; do
    am force-stop "$SVC" 2>/dev/null
done

say "✅ سيتم حذف الوحدتين بعد إعادة الإقلاع"
sync 2>/dev/null
reboot 2>/dev/null || /system/bin/reboot 2>/dev/null
