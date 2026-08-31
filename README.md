# AndrOS

Android telefonunu Mac'e bağlar: ekran, dosyalar, mesajlar, bildirimler,
kamera ve ses. Kablo şart değil, geliştirici seçenekleri gerekmiyor.

> Türkçe ve İngilizce arayüz; dil işletim sisteminden seçiliyor.

## Ne yapıyor

| | |
|---|---|
| **Ekran yansıtma** | Telefon ekranı Mac'te, fare ve klavyeyle kontrol |
| **Bildirimler** | Telefon bildirimleri macOS'ta — kendi düğmeleriyle, banner'dan yanıt |
| **Mesajlar / aramalar** | SMS oku-yaz, rehberden ara, arama geçmişini yönet |
| **Dosyalar / galeri / müzik** | Finder gibi gezinme, iki yönlü sürükle-bırak |
| **Telefon = webcam** | Ön/arka kamera, döndürme ve efektlerle; kamera kullanan her uygulamada |
| **Telefon = ses aygıtı** | Mac'in sesi telefondan çıkar, telefonun mikrofonu Mac'te görünür |

## Nasıl çalışıyor

İki parça var: **macOS uygulaması** (Swift/AppKit) ve **Android
uygulaması** (Kotlin). Aralarında telefonun kendi sertifikasıyla kurulan,
parmak izi sabitlenmiş bir **TLS** bağlantısı var.

Telefon uygulaması kurulduktan sonra `adb` ve geliştirici seçenekleri
**gerekmiyor**; USB ve Wi-Fi aynı yoldan çalışıyor. `adb` yalnızca
uygulama henüz eşleşmemişken bir geri düşüş yolu.

Bulma iki kanaldan: Bonjour (mDNS) ve UDP yayın/tarama. İkincisi şart —
Wi-Fi yongası güç tasarrufunda multicast'i süzüyor ve bazı yönlendiriciler
hiç geçirmiyor.

Ayrıntılar ve **ölçülmüş** tasarım kararları: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Derleme

Gereken: Xcode komut satırı araçları, JDK 17+, Android SDK.

```bash
tools/install.sh          # macOS uygulaması -> /Applications
tools/android.sh assembleDebug install   # APK -> bağlı telefon
```

Sanal kamera ve ses sürücüsü uygulama paketinin içinde gelir; kurulumu
uygulamanın kendisi yapar (macOS parola sorar).

## İmza ve güvenlik

AndrOS, Apple'a kayıtlı bir geliştirici sertifikasıyla imzalı değil.
Bu yüzden:

- İlk açılışta macOS uyarır: uygulamaya **sağ tık → Aç**, ya da
  Sistem Ayarları → Gizlilik ve Güvenlik → "Yine de aç".
- Sanal kamera bir **sistem uzantısı**; imzasız kurulum için bir kez
  `systemextensionsctl developer on` gerekiyor.

Eşleştirme belirteçleri ve sertifika parmak izleri **yalnızca cihazda**
saklanır; hiçbir sunucuya gitmez. Uygulamanın kendi sunucusu yoktur.

## Lisans

[Apache License 2.0](LICENSE). scrcpy sunucu bileşeni için bkz.
[NOTICE](NOTICE).
