# AndrOS Signal

İki AndrOS cihazını internet üzerinden buluşturan **en küçük** servis.

## Neden bir sunucu var?

İstenen "ara sunucu olmasın"dı ve bunu olabildiğince yerine getiriyoruz —
ama tamamen sıfır sunucu **mümkün değil**: iki cihaz da NAT arkasındaysa
birbirlerinin adresini bilemezler ve ilk paketi kimse gönderemez. Birinin
tanıştırması gerekiyor. Bu servis yalnızca o tanıştırmayı yapar:

- **Görmediği şeyler**: mesaj içeriği, ses, görüntü, kişi listesi, kimin
  kiminle konuştuğunun geçmişi. Hiçbiri sunucudan geçmiyor ve hiçbiri
  diske yazılmıyor.
- **Gördüğü şeyler**: hangi cihaz kimliği o an bağlı, kime paket iletmesi
  istendi, paketin boyutu ve zamanı. Bunlar iletmek için zorunlu.
- Konuşma başladıktan sonra ses ve görüntü **doğrudan cihazdan cihaza**
  gider; sunucu devrede değildir.

Sunucu senin. Kimlik doğrulama hesap/parola değil, cihazın kendi
anahtarıyla imza — yani sunucunun kullanıcı veritabanı yok.

## Adresleme

Her cihazın bir Ed25519 kimlik anahtarı var. Adres = açık anahtarın
SHA-256 özetinin ilk 10 baytı, Crockford base32 ile yazılmış hâli
(16 karakter). Buna **AndrOS Kimliği** diyoruz.

Telefon numarasıyla arama için sunucuda `numara → kimlik` eşlemesi
tutuluyor, ama numaranın **kendisi değil**: `HMAC-SHA256(sunucu tuzu,
E.164 numara)`nın ilk 16 baytı. Sunucu numaraları listeleyemez; yalnızca
elinde bir numara varken karşılığını arayabilir. Tuz sunucuda kalır ve
`.env` ile verilir.

## Protokol

WebSocket, `/ws`. Her çerçeve tek bir JSON nesnesi.

### 1. Bağlanma ve kanıt

```
S→C  {"t":"hello","challenge":"<b64, 32 bayt>","v":1}
C→S  {"t":"auth","key":"<b64 Ed25519 açık anahtar>",
      "sig":"<b64 challenge imzası>","numbers":["<b64 numara özeti>", …]}
S→C  {"t":"ready","id":"<AndrOS kimliği>"}
```

`numbers` isteğe bağlı: cihaz hangi numaralardan bulunabileceğini
bildirir (kendi hattı). Sunucu bunları yalnızca bellekte tutar ve
bağlantı kapanınca siler.

### 2. Ulaşılabilirlik

```
C→S  {"t":"lookup","of":["<numara özeti>", …]}
S→C  {"t":"presence","found":{"<özet>":"<kimlik>"},"missing":["<özet>"]}
```

Bu, "karşı tarafta uygulama var mı ve interneti açık mı" sorusunun
cevabı. `missing` ise arama yapılamaz — kullanıcıya normal GSM araması
önerilir.

### 3. İletme

```
C→S  {"t":"send","to":"<kimlik>","env":"<b64 mühürlü zarf>"}
S→C  {"t":"recv","from":"<kimlik>","env":"<b64>"}
S→C  {"t":"undeliverable","to":"<kimlik>"}        (karşı taraf bağlı değil)
```

`env` sunucu için anlamsız bir bayt dizisi. İçindekini yalnızca iki uç
açabiliyor: X25519 (kimlik anahtarlarından türetilen) ortak sır → HKDF →
XChaCha20-Poly1305. Arama daveti, cevabı, aday adresler ve metin
mesajları hep bunun içinde gider.

### 4. Adres öğrenme (STUN)

Aynı makinede UDP `:3478` üzerinde RFC 5389 Binding isteğine cevap veren
küçük bir uç var. Cihaz kendi dış adresini oradan öğrenip zarfın içinde
karşı tarafa yolluyor; ardından iki taraf birbirine aynı anda paket
göndererek NAT'ta delik açıyor (hole punching).

Bağlantı kurulamazsa (simetrik NAT, operatör CGNAT) arama kurulamaz;
röle **yok**. Röle eklenirse trafiği taşır ama içeriği yine göremez.

## Çalıştırma

```sh
cp .env.example .env      # PORT ve SIGNAL_SALT
docker compose up -d
```

`SIGNAL_SALT` değişirse tüm numara eşlemeleri geçersiz olur — bir kez
üret ve sakla.
