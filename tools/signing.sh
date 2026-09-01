#!/bin/bash
# macOS imza kimligi — TEK VE DEGISMEZ.
#
# NEDEN: `codesign --sign -` (ad-hoc) imzasi paketin ICERIGINDEN
# turetiliyor, yani her derlemede degisiyor. macOS'un izin veritabani
# (TCC) izni uygulamanin imzasina bagliyor; imza degisince kayit
# eskiyor. Sonuc olculdu: Sistem Ayarlari'nda "Erisilebilirlik"
# listesinde AndrOS ISARETLI gorunuyor ama izin GECERSIZ — telefondan
# yonetme calismiyor ve tek cozum kaydi silip elle yeniden eklemek.
#
# Kendi imzaladigimiz sabit bir sertifikayla imzalayinca "designated
# requirement" su hale geliyor:
#     identifier "dev.naer.andros" and certificate root = H"..."
# Bu, paket icerigine BAGLI DEGIL — guncelleme izni bozmuyor.
#
# Sertifika Apple'a kayitli degil (kayit yillik ucret istiyor).
# Gatekeeper icin bir sey degistirmiyor; degistirdigi tek sey iznin
# guncellemeden sonra da gecerli kalmasi.
set -e

SUPPORT="$HOME/Library/Application Support/AndrOS"
KEYCHAIN="andros-signing.keychain"
KEYCHAIN_PW="andros-local"
P12="$SUPPORT/andros-codesign.p12"
NAME="AndrOS Code Signing"

mkdir -p "$SUPPORT"

# 1. Sertifika yoksa uret. Bir kez uretiliyor ve SAKLANIYOR: kaybolursa
#    imza degisir ve kullanicilarin izni bir kez daha vermesi gerekir.
if [ ! -f "$P12" ]; then
  TMP="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -subj "/CN=$NAME/O=AndrOS" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null
  # ESKI algoritmalar ZORUNLU: OpenSSL 3'un varsayilani (AES-256 + SHA-256
  # MAC) Apple'in Security cercevesince okunamiyor, "MAC verification
  # failed" diyor.
  openssl pkcs12 -export -out "$P12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -passout "pass:$KEYCHAIN_PW" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null
  rm -rf "$TMP"
  echo "imza sertifikasi uretildi: $P12"
fi

# 2. Anahtar zinciri. AYRI bir zincir kullaniyoruz: giris zincirine
#    yazmak kullanicinin parolasini sormayi gerektiriyor.
#
# Acilmiyorsa (baska bir parolayla kalmis eski bir zincir) YIKIP yeniden
# kuruyoruz: iceride sertifikadan baska bir sey yok, kaybedilecek sey de
# yok. Bunu yapmadan `set -e` betigi yarida kesiyor ve paket sessizce
# imzasiz kaliyordu.
if ! security list-keychains -d user | grep -q "$KEYCHAIN" \
   || ! security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN" 2>/dev/null; then
  security delete-keychain "$KEYCHAIN" 2>/dev/null || true
  security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
  EXISTING=$(security list-keychains -d user | sed 's/"//g' | xargs)
  security list-keychains -d user -s $EXISTING "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
fi
# Kilit ZAMAN ASIMINA UGRAMASIN: uzun derlemede zincir kendiliginden
# kilitlenip imzalama yarida kaliyordu.
security set-keychain-settings "$KEYCHAIN"

if ! security find-identity -p codesigning "$KEYCHAIN" | grep -q "$NAME"; then
  security import "$P12" -k "$KEYCHAIN" -P "$KEYCHAIN_PW" -T /usr/bin/codesign -A >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null 2>&1 || true
  echo "imza kimligi anahtar zincirine eklendi"
fi

# bundle.sh bunlari okuyor.
export ANDROS_SIGN_IDENTITY="$NAME"
export ANDROS_SIGN_KEYCHAIN="$KEYCHAIN"
