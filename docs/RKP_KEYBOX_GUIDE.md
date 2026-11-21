# استخراج كيبوكس RKP من جهازك — دليل v3.33

## لماذا هذا الطريق؟

في 20–21 نوفمبر 2026 بطلّت Google **كل** الكيبوكسات العامة المعروفة (TAKR 45، Yurikey 70، Droidwin 4.2B، أرشيف Integrity-Box، إلخ)، حتى المفاتيح الخاصة غير المنشورة. لم يعد هناك ملف عام صالح يمكن تضمينه في الحزمة.

الحل الوحيد للحصول على كيبوكس نظيف اليوم هو أن **يطلب جهازك شهادة RKP خاصة به مباشرة من Google**: يُولَّد مفتاح P-256، يوقّع جهازك CSR عبر KeyMint TA، ثم تُصدر Google سلسلة شهادات قصيرة العمر. المفتاح الخاص لا يُستخرج من TEE؛ الموديول يولّده ويوقّع عليه الجهاز.

> ⚠️ شهادات RKP قصيرة العمر (حوالي 12–14 يومًا). فعّل التحديث التلقائي في الأداة التي تختارها.

---

## الطريقة (أ) — TeeForge-CD [موصى بها]

**المتطلبات:** جهاز arm64 بمعالج Qualcomm، root (Magisk / KernelSU / APatch)، ووجود:
- `/dev/smcinvoke`
- `/vendor/lib64/libkeymasterdeviceutils.so`

### الخطوات

1. نزّل أحدث موديول من:
   `https://github.com/mcxiaochenn/TeeForge-CD/releases/latest`
   (الملف `teeforge_cd-vX.XX.zip`).

2. ثبّته من مدير root ثم أعد الإقلاع.

3. افحص التوافق (لا يرسل أي طلب للشبكة):
   ```sh
   su -c '/data/adb/modules/teeforge_cd/runtime/teeforge --rkp-status'
   ```
   إن ظهرت كل الشروط `ok` تابع. إن ظهر `TA status -18` فالجهاز غير مدعوم — جرّب الطريقة (ب).

4. شغّل مساعد FALCON المرفق مع v3.33 (إصدار + فحص CRL + تثبيت):
   ```sh
   su -c 'sh /data/adb/modules/falcon_integrity_fix/rkp_keybox_helper.sh --all'
   ```

5. لإخراج الملف لإدماجه في نسخة الاختبار:
   ```sh
   su -c 'sh /data/adb/modules/falcon_integrity_fix/rkp_keybox_helper.sh --export'
   ```
   انسخ السطر الذي يبدأ بـ `FALCON_RKP_KB64=` وأرسله للمطور.

الملف الناتج: `/data/adb/teeforge/RKP/keybox.xml`

---

## الطريقة (ب) — Duck ToolBox (WebUI)

1. ثبّت موديول Duck ToolBox من:
   `https://github.com/eltavine/Duck-ToolBox/releases/latest`
2. افتح WebUI للموديول ← **Device RKP Issuer**.
3. وافق على تحذير القيود، ثم اختر البروتوكول `auto` (أو `v2` للـ Qualcomm الحديث).
4. اضغط **Issue now**. الناتج: `/data/adb/duck/rkp/keybox.xml` (أو المسار الذي يعرضه الـ WebUI).
5. انسخ الملف إلى `/data/adb/teeforge/RKP/keybox.xml` ثم أكمل:
   ```sh
   su -c 'sh /data/adb/modules/falcon_integrity_fix/rkp_keybox_helper.sh --verify'
   su -c 'sh /data/adb/modules/falcon_integrity_fix/rkp_keybox_helper.sh --export'
   ```

---

## الطريقة (ج) — rkp-mini

موديولان: **Issuer** على جهاز Qualcomm، و**Deployer** على الجهاز المستقبل:
`https://github.com/etnperlong/rkp-mini/releases/latest`

الناتج: `/data/misc/keystore/rkp-mini/output/keybox.xml`. انسخه إلى مسار TeeForge أعلاه ثم أكمل كما في الطريقة (ب).

---

## الطريقة (د) — على الحاسوب (متقدمة)

إن كان لديك بذرة `CDI_Leaf` الخاصة بجهازك (32 بايت) يمكنك توليد كيبوكس على الحاسوب:

```sh
git clone https://github.com/MhmRdd/google-rkp-sw.git
cd google-rkp-sw
pip install cbor2 cryptography
cp template.conf device_prop.conf   # عدّل قيم الجهاز
python3 rkp_sw.py keybox --seed <64-hex> --config device_prop.conf -o keybox.xml
```

هذه الطريقة تتطلب استخراج البذرة من TEE، وهي أخطر وأصعب من الطرق السابقة.

---

## بعد الاستخراج

- المساعد يتحقق تلقائيًا من: البنية، بصمة الكيبوكس الكلاسيكي، وقائمة إبطال Google
  (`android.googleapis.com/attestation/status`) قبل التثبيت.
- لا تُرسل الكيبوكس إلى أي موقع عام — كل نسخة عامة تُبطل خلال ساعات.
- أعد الإقلاع بعد التثبيت، ثم تحقق من نتيجة Play Integrity.
- لإدماج الكيبوكس في نسخة v3.33 المعدّلة: أرسل سطر `FALCON_RKP_KB64=` للمطور؛
  سيُعاد بناء الحزمة بكيبوكسك الخاص.
