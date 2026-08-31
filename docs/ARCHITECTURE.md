# AndrOS — Mimari

## Sorun tanımı
scrcpy'nin görüntüsü telefona kıyasla soluk ve oyun için yetersiz. Beş ayrı
sebep üst üste biniyor:

1. **Renk aralığı uyuşmazlığı** — encoder full-range (0-255) YUV üretirken
   renderer limited-range (16-235) varsayıyor. Siyahlar grileşiyor.
2. **Matris uyuşmazlığı** — BT.601 vs BT.709 karışması tonu ve doygunluğu kaydırıyor.
3. **Panel post-processing yakalanamıyor** — telefonun "Canlı/Vivid" doygunluğu
   framebuffer'a yazıldıktan *sonra* uygulanıyor. Yakalanan veride hiç yok.
   Client tarafında yeniden üretilmesi gerekiyor.
4. **4:2:0 chroma + düşük bitrate** — renk çözünürlüğü yarıya iniyor, banding.
5. **Monitör gamut limiti** — sRGB panel, telefonun P3 doygunluğunu basamaz. (Fiziksel, çözülemez.)

1, 2 ve 4 tamamen çözülebilir. 3 taklit edilebilir. 5 kabul edilir.

## Donanım kısıtları (geliştirme makinesi)
- i5-9400F: iGPU yok → **Quick Sync yok**. Decode RX 580 UVD üzerinden.
- RX 580: H.264 ✅ HEVC ✅ **AV1 ❌** → AV1 asla kullanılmayacak.
- Ekran: 1920x1080 @ 120Hz, RGB 10-bit (ARGB2101010).
- Xcode yok, sadece CLT → Metal shader'ları **runtime'da** derlenecek
  (`device.makeLibrary(source:)`), doğrulandı.

## Neden adb zorunlu (tasarımla kaçınılamaz)
Normal bir Android uygulaması:
- Başka uygulamalara **dokunma/tuş enjekte edemez** (`INJECT_EVENTS` signature izni)
- Android 10+ **arka planda pano okuyamaz**
- MediaProjection her oturumda onay diyaloğu + yayın simgesi gösterir

Bu yüzden yakalama+girdi bileşeni **shell UID** altında (`app_process`, adb ile)
çalışmak zorunda. scrcpy de aynı sebeple böyle yapıyor. Root olmadan alternatifi yok.
Kablosuz hata ayıklama (Android 11+) ile kablosuz da çalışır.

## Bileşenler
| Bileşen | Çalışma yeri | Sorumluluk |
|---|---|---|
| `AndrOS.app` | macOS, Swift | Render, girdi, menü çubuğu, SMS/bildirim arayüzü |
| `andros-agent` | Android, shell UID (adb) | Ekran yakalama, girdi enjeksiyonu, pano |
| `AndrOS Companion` | Android, normal APK | SMS, bildirim dinleyici, dosya, Mac'i kontrol |

## Fazlar
**Faz 1 (şu an)** — Taşıyıcı olarak scrcpy-server (Apache-2.0) kullanılıyor.
Amaç: renk/gecikme tezini kanıtlamak. Sorunun kodu Mac tarafında.

Kritik bulgu: scrcpy sunucusu `video_codec_options` parametresini destekliyor,
bu MediaCodec'e doğrudan geçiyor. Yani kendi sunucumuzu yazmadan da
`color-range=1` (FULL), `color-standard=1` (BT709), `color-transfer=3` zorlanabilir.

**Faz 2** — Kendi agent'ımız: encoder tam kontrol, 10-bit HEVC, düşük gecikmeli
çoklu dokunma, tuş haritalama.

**Faz 3** — Companion app + entegrasyon (SMS, bildirim, pano, Live Updates).

## Faz 1 veri yolu
```
Android MediaCodec ──H.264/HEVC──> adb forward ──TCP──> Demuxer
   └─> VTDecompressionSession (RX 580 donanım)
       └─> CVPixelBuffer (NV12)
           └─> CVMetalTextureCache → Metal compute shader
               ├─ doğru matris + range dönüşümü   (sebep 1,2)
               ├─ vibrance / gamut genişletme      (sebep 3)
               └─ bicubic chroma upsample + dither (sebep 4)
                   └─> CAMetalLayer (120Hz, maximumDrawableCount=2)
```

## Tel protokolü (scrcpy 4.1, kaynaktan doğrulandı)
Sunucu: `CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / com.genymobile.scrcpy.Server 4.1 <k=v>...`
Soket sırası: video, audio, control. Forward tünelde ilk sokette 1 bayt dummy,
ardından 64 bayt cihaz adı.

Video soketi: `codec_id` u32 ("h264"=0x68323634, "h265"=0x68323635).
Sonra 12 baytlık başlıklar:
- MSB=1 → **session packet**: bayt 0-3 bayrak, 4-7 genişlik, 8-11 yükseklik
- MSB=0 → **media packet**: bit62=config, bit61=keyframe, kalan 61 bit PTS, 8-11 boyut

## Makine kısıtı: Bluetooth ve Wi-Fi yok
- Bluetooth denetleyicisi (BCM_4350C2) var ama firmware yüklenmemiş
  (`Address: NULL`, `State: Off`) → **kullanılamaz**.
- **Wi-Fi arayüzü hiç yok.** Tek ağ: Ethernet `en0` (192.168.1.195).

Sonuçları:
- Eşleşme/keşif **Bluetooth ile olamaz** → LAN üzerinden mDNS/Bonjour
  (`_andros._tcp`) + eşleşme kodu kullanılacak.
- Telefon Wi-Fi'da, Mac Ethernet'te, ikisi de aynı /24 → LAN özellikleri çalışır.
- Aynalama birincil yolu **USB** (en düşük gecikme); ağdan bağımsız.
- Bu makinede Apple Continuity (Handoff/AirDrop/Universal Clipboard) donanım
  eksikliğinden zaten çalışmıyor. AndrOS bunun yerini dolduruyor.

## Olculen gercekler — RMX2040 (realme 6i), 2026-08-30

Cihaz: realme RMX2040, Android 11 (API 30), ColorOS/Realme UI, MT6768 (Helio G80).

| Olcum | Deger | Kaynak |
|---|---|---|
| Panel | 720x1600, **tek mod, 60.0 fps** | `dumpsys display` supportedModes |
| Renk modu | `colorMode 0, supportedColorModes [0]` = **yalniz sRGB** | dumpsys display |
| HDR | `mSupportedHdrTypes=[]`, 500 nit | dumpsys display |
| Encoder (donanim) | `OMX.MTK.VIDEO.ENCODER.AVC`, `.HEVC` | scrcpy --list-encoders |
| Varsayilan renk sinyali | LIMITED range, BT.709 primaries/transfer/matrix | AndrOS SPS parser |
| `color-range=1` zorlanmis | **FULL range'e gecti — encoder kabul ediyor** | AndrOS SPS parser |
| Akis (oyun, yatay) | 1600x720 @ 44 FPS, 13.1 Mbps, 36.4 KB/kare (h264) | androsctl probe |
| Ayni, HEVC | 43.8 FPS, **17.8 Mbps** (daha kotu), Main profil | androsctl probe |
| Oyun cizim suresi | 50p **5ms**, 90p 6ms, GPU 3ms, jank %1.43 | dumpsys gfxinfo |
| CPU toplam | %27 | dumpsys cpuinfo |

### Cikarimlar
1. **Darbogaz telefonun GPU'su degil, 720p panel.** Oyun 5ms'de kare ciziyor
   (16.6ms butcesinde), GPU 3ms. 1080p'ye cikarilsa ~7ms olurdu — hala 60fps sigar.
2. **Renk duzeltmesi kaynakta mumkun ve dogrulandi:** LIMITED -> FULL calisiyor.
   Matris/primaries zaten dogru (BT.709), yani o hipotez bu cihazda gecersiz.
3. **HEVC bu donanimda avantaj saglamiyor** (daha fazla bit, ayni fps, ekstra
   gecikme) -> **H.264 kullanilacak.**
4. Panel sRGB-only ve HDR yok -> genis gamut geri kazanimi diye bir sey yok.
   Shader'daki doygunluk kontrolu bir *tercih* ayari olacak, sadakat degil.
5. 44 FPS icerik kaynakli (SurfaceFlinger yalnizca degisiklikte kare uretir),
   encoder limiti degil.

### Acik engel: ColorOS WRITE_SECURE_SETTINGS
`wm size` ve `overlay_display_devices` engelli:
`SecurityException ... OppoWindowManagerService`. `pm grant` de engelli
(`GRANT_RUNTIME_PERMISSIONS` yok). Tek cozum cihaz tarafinda:
Gelistirici secenekleri -> **"Izin izlemeyi devre dizi birak"** (listenin en alti),
ardindan USB hata ayiklamayi kapat/ac.
Android 11 oldugu icin scrcpy `--new-display` (Android 14+) da kullanilamaz.
Bu ayar acilirsa 720p tavani kalkar; en yuksek kaldirac bu.

## Faz 1 tamamlandi — dogrulanan hat (2026-08-30)
Ucdan uca calisiyor ve gorsel olarak kanitlandi:
`adb -> scrcpy-server -> TCP -> demuxer -> VideoToolbox (RX 580) -> Metal -> CAMetalLayer`
ve geri yonde `mouse/klavye -> kontrol soketi -> dokunma enjeksiyonu`.

Kanit: `androsctl inputtest --x 905 --y 505` giris ekranindaki "Bolge Degistir"e
basti, oyun "Sunucu Sec" diyalogunu acti ve o kare kendi render hattimizdan
PNG olarak kaydedildi.

### Yol boyunca cikan iki gercek hata (ikisi de duzeltildi)
1. **Soket sirasi**: scrcpy sunucusu 64 baytlik cihaz adini ancak BEKLENEN TUM
   soketler baglandiktan sonra yaziyor. Kontrol soketini baglamadan once okumaya
   calisinca kilitleniyordu. `probe`'da control kapali oldugu icin gorulmemisti.
2. **Layer sirasi**: AppKit'te layer-hosting view icin `layer` atamasi
   `wantsLayer = true`den ONCE gelmeli; tersi olursa CAMetalLayer degistiriliyor.

### Dogrulanamayan sey
`show_touches` ve `wm size` ayni ColorOS `WRITE_SECURE_SETTINGS` engeline takiliyor.
Dokunma dogrulamasi bu yuzden gosterge yerine gercek UI tepkisiyle yapildi.

### Compact davranis
`LSUIElement=1` -> dock'ta HIC ikon yok, yalniz menu cubugunda tek simge.
adb alt surecleri app bundle olmadigi icin dock'a hic dusmez (scrcpy'nin iki
ikon gosterme sorunu burada yapisal olarak yok). Menuden "Dock'ta goster"
ile istenirse tek ikon acilabilir.

## Compact/dagitim kararlari
- `LSUIElement=1`: dock'ta ikon yok, yalniz menu cubugunda tek simge.
- **Pencere `.floating`**: dock ikonu olmadigi icin pencere arkaya duserse geri
  getirilemiyordu. Her zaman ustte tutmak bunun yapisal cozumu. Menuden kapatilabilir.
- **Tek ornek**: ayni bundle id'den ikinci ornek varsa one getirilip cikilir.
  Ayrica `applicationShouldHandleReopen` ile Launchpad'den tekrar acinca pencere
  one gelir (dock ikonu olmadigi icin bu olmadan "hicbir sey olmuyor" gibi gorunur).
- **Gorunur hata**: cihaz yoksa veya baglanti duserse NSAlert gosterilir.
  Agent uygulamasinin sessizce hicbir sey yapmamasi en kotu davranis.
- **Sunucu jar'i paket icinde** (`Contents/Resources/scrcpy-server` + `VERSION`).
  Sistemdeki scrcpy kurulumuna ve surumune bagimlilik yok; surum stringi jar'in
  yanindaki dosyadan okundugu icin ikisi ayrisamaz.
- **Kurulum**: `tools/install.sh` -> /Applications, ve build/ kopyasinin
  LaunchServices kaydini siler (yoksa iki AndrOS gorunur).

## Renk hatasi: encoder etiketi yaliyor (2026-08-30)
`video_codec_options=color-range=1` verildiginde MediaTek encoder akisi FULL
range diye ETIKETLIYOR ama piksel verisini limited birakiyor. Olculdu:

| yapilandirma | VT piksel formati | gercek luma araligi |
|---|---|---|
| color-range=1 zorlanmis | `420f` (FULL) | **16..228 (LIMITED)** |
| varsayilan | `420v` (LIMITED) | 16..228 (LIMITED) ✓ |

Sonuc: VideoToolbox etikete inaniyor, shader "zaten full" deyip
(Y-16)/219 genisletmesini atliyor -> siyahlar gri, goruntu soluk.
**Yani renk "duzeltmesi" solukluga sebep oluyordu.**

Alinan onlem:
1. `color-range` zorlamasi KALDIRILDI.
2. Etikete guvenilmiyor; ilk 15 karede gercek luma dagilimina bakiliyor.
   Esik %3 — ilk denemede %0.2 kullanildi ve kayipli sikistirmanin
   ringing gurultusu yuzunden LIMITED icerigi yanlislikla FULL sandi
   (olculen gercek tasma: %0.14).

Ders: metadata dogrulamasi yeterli degil, PIKSELLERE bakmak gerekiyordu.

## Judder olcumu
Kare gelis araliklari (429 kare / 8 sn): ortalama 17.0ms (58.9 FPS),
ortanca 16.9ms, std sapma 5.0ms, %95=24ms, 33ms ustu bosluk %2.
Kare hizi dusuk DEGIL; gorunen takilma o %2'lik gec kalan kareler.
Onlem: 2 derinlikli kare kuyrugu (menude "Akicilik onceligi", +~17ms).
Atlanan kare 0-12'den 0-3'e dustu.

## Ekran kurtarma
scrcpy paneli SurfaceControl ile sonduruyor; PowerManager bunu bilmiyor,
bu yuzden KEYCODE_WAKEUP paneli geri ACMIYOR. Uygulama anormal olurse
telefon sonuk kaliyordu. Eklendi: SIGTERM/SIGINT/SIGHUP isleyicileri,
menude "Telefon ekranini simdi ac", ve `androsctl screen on`.

## Akicilik: kaynak siniri vs sunum siniri (olculdu)
Sunum hiz duzenleyicisi (pacer) oncesi/sonrasi:

| | once | sonra |
|---|---|---|
| sunum sapmasi (sd) | 8-13 ms | **3.6-6.9 ms** |
| p95 | 33 ms | **25 ms** |
| en kotu bosluk | 50-92 ms | **25 ms** |

Pacer: kareyi geldigi tick'te degil, kaynagin EMA ile olculen ritminde sunar.
Kuyruk derinligi 4, 3'u asarsa gecikme birikmesin diye yetisir.

**Kaynak siniri degistirilemiyor.** Gercek oyun sahnesinde telefon ~44 FPS
uretiyor ve karelerin %6'si gec geliyor. Test edildi:

| ayar | FPS | sd |
|---|---|---|
| 24 Mbps | 44.1 | 9.0 ms |
| 12 Mbps | 41.0 | 14.3 ms |
| 6 Mbps  | 43.7 | 7.2 ms |
| 24 Mbps + 1280 | 44.5 | 6.8 ms |

Bitrate ve cozunurluk fark etmiyor -> encoder darbogaz DEGIL, kaynak (oyun +
SurfaceFlinger) sinirli. Bu yuzden kalite dusurulmuyor, 24 Mbps korunuyor.
Not: giris ekraninda 58.9 FPS / %2 gec olcuulmustu; fark oyun sahnesi yuku.

## Panel tipi: AMOLED DEGIL
`ro.lcd.backlight.config_hlt/truly/txd` (uc LCD panel tedarikcisi icin arka
aydinlatma kalibrasyonu) + `supportedColorModes [0]` -> **IPS LCD, sRGB-only**.
Geniş gamut geri kazanimi diye bir sey yok; telefondaki canlilik panelin kendi
karakteri. Varsayilanlar buna gore: doygunluk 1.15, keskinlik 0.45, kontrast 1.05.

## Pencere ve uygulama kimligi
- Pencere **kenarliksiz** (`.borderless` + `MirrorWindow` ile canBecomeKey).
  Baslik cubugu varken ustten surukleme pencereyi tasiyordu ve Android bildirim
  panelini asagi cekmek imkansizdi. Artik pencerenin tamami goruntu.
- `isMovable = false` + `isMovableByWindowBackground = false`; tasima YALNIZ
  ⌘ + sol tik surukleme ile (MetalView elle takip ediyor, performDrag calismaz).
- `LSUIElement` KALDIRILDI -> dock'ta gercek ikonla gorunuyor, ⌘Tab calisiyor.
  Tek bundle. Standart ana menu eklendi (⌘Q, ⌘W, ⌘M).
- Ikon `tools/makeicon.swift` ile uretiliyor (CoreGraphics), `build/AndrOS.icns`.

## Faz 3 basladi: pano senkronizasyonu
Kontrol soketi CIFT YONLU — cihaz da bize mesaj gonderiyor
(`device_msg.c`: tip u8, CLIPBOARD=0 icin [len u32][utf8]).
Ayri bir Android uygulamasi gerekmeden pano senkronu bu kanaldan yapildi.

- Mac -> telefon: `NSPasteboard.changeCount` yoklanip SET_CLIPBOARD
  (`[9][seq u64][paste u8][len u32][metin]`). NSPasteboard'un degisiklik
  bildirimi olmadigi icin 0.7 sn'lik yoklama tek yol.
- Telefon -> Mac: kontrol soketinde ayri okuma is parcacigi.
- Dongu korumasi: son senkronlanan metin hatirlanip tekrar gonderilmiyor.

Dogrulama: `androsctl cliptest` tam tur yapiyor (gonder -> cihazin gercek
ClipboardManager'i -> geri iste -> karsilastir). BASARILI.

## Pencere gorunumu
Kenarliksiz pencerede `metalLayer.cornerRadius = 12` + `masksToBounds`
+ `cornerCurve = .continuous`; pencere `isOpaque = false`,
`backgroundColor = .clear` ki koselerin disi seffaf kalsin ve golge otursun.

## ColorOS izni: HALA ACILMADI (2026-08-30)
`com.android.shell` paketinde `WRITE_SECURE_SETTINGS: granted=true` GORUNUYOR
ama `SettingsProvider.enforceWritePermission` yine reddediyor -> engel Oppo'nun
provider'a ekledigi ekstra kontrol, standart izin sistemi degil.
`content insert` ile dogrudan provider'a yazmak da ayni yerde reddediliyor.
Muhtemelen yeniden baslatma gerekiyor ya da Realme UI 2'de anahtarin adi
"USB hata ayiklama (Guvenlik ayarlari)" ve Realme hesabi + SIM istiyor.
720p tavani bu acilana kadar duruyor.

## Yan panel (BlueStacks tarzi arac cubugu)
`SidebarView` + `MirrorContentView` ile ayna goruntusunun yaninda dikey panel.

- Konum: varsayilan SAG, "Tarafi degistir" dugmesi veya ayarlardan SOL.
- Gorunurluk: ayarlardan kapatilabilir, **⌘⌥S** ile geri gelir (panel gizliyken
  ayarlar dugmesi de gizlenecegi icin global kisayol sart).
- Hangi dugmelerin gorunecegi ayarlar popover'indan secilir; secim
  `UserDefaults[sidebarActions]` icinde saklanir. Ayarlar dugmesi her zaman kalir.

Eylemler: geri, ana ekran, gorev gorunumu, bildirim paneli, ekran goruntusu,
dondurme, tus haritalama, ses +/-, guc, telefon ekrani, tam ekran,
taraf degistir, ayarlar.

Ekran goruntusu son cizilen kareyi TAM render hattindan gecirip hem panoya
(`NSPasteboard .png`) hem `~/Pictures/AndrOS/` altina yaziyor.

## Tus haritalama (KeyMapper)
Emulatorlerin asil avantaji. Uc BAGIMSIZ parmak kullaniliyor:

| pointer id | kullanim |
|---|---|
| 0 | fare (dokunma) |
| 1 | WASD sanal analog cubuk |
| 2 | yetenek tuslari (1-5, boşluk) |

Ucu ayni anda basili olabiliyor. Cubuk merkezi/yaricapi ve tus konumlari
oransal (0..1) tanimli, cozunurlukten bagimsiz.
`MetalView.onRawKey` once haritalayiciya soruyor; o tuketirse olay oyuna
ayrica gonderilmiyor.

### Test tuzagi
`androsctl uitest`'in ilk surumu tus DOWN gonderip 1.6 sn bekleyip UP
gonderiyordu — bu UZUN BASMA demek ve HOME'a uzun basinca Google Asistan
aciliyordu. Gercek `tapKey` down+up'i beklemeden gonderiyor. Duzeltildikten
sonra: ana ekran -> launcher, gorev gorunumu ve geri dogru calisti.

## Galeri: video küçük resimleri ve sahte videolar

**Küçük resim.** Videoyu indirip kare çıkarmak yerine MediaStore'un hazır
küçük resmini alıyoruz:

    adb exec-out content read --uri content://media/external/video/media/<id>/thumbnail

Ölçüldü: ~24 KB, videonun kendisi 0.8–1.9 MB. `.../video/thumbnails` tablosu
"No result found" veriyor; çalışan yol öğe başına `/thumbnail` soneki.
Bunun için `MediaItem`'a `mediaID` alanı eklendi (`_id` projeksiyonu).

**İmza doğrulaması.** Küçük resmi olmayan bir video için `content read`
çıkış kodu 0 veriyor ama stdout'a 644 baytlık `Error while accessing
provider:media / java.io.FileNotFoundException: Failed to create thumb`
metnini basıyor. `RawProcess.runToFile`'ın >512 bayt kontrolünü geçtiği için
bozuk bir "jpg" önbelleğe giriyordu. `AndroidData.isImage` artık JPEG/PNG/
GIF/WEBP imzasına bakıyor; geçmeyen dosya siliniyor ve yerine `.miss`
işaret dosyası bırakılıyor ki her açılışta yeniden denenmesin. Aynı kontrol
albüm kapaklarına da uygulandı.

**Sahte videolar.** Android MIME türünü yalnız UZANTIYA bakarak atıyor, bu
yüzden `.ts` uzantılı TypeScript kaynak dosyaları `video/mp2ts` sayılıp
video listesine giriyordu. Ölçüldü: `enum.effect.ts` 57 KB, `gli.keys.ts`
503 B, `core.ts` 10 KB — üçünde de `duration`/`width`/`height` = NULL,
gerçek 70 videonun hepsinde dolu. Ayırt etme ölçütü uzantı değil `duration`;
böylece Android'in yanlış etiketlediği her tür dosya elenir. Liste 73 → 70.

## Arama: joker karakter

`SearchMatch` (`mac/Sources/AndrOSApp/SearchMatch.swift`) `*` jokerini
destekliyor: `*jpg`, `jpg*`, `IMG*jpg`, `*WA*`. `*` yoksa eski davranış
(alt dize araması) aynen korunuyor, yani mevcut kullanım bozulmuyor.
Yedi panelin filtresi de buna bağlandı: Galeri, Dosyalar, Uygulamalar,
Mesajlar, Kişiler, Pano, Müzik (parça listesi + grid + çalma listesi adı).
Canlı doğrulama: filtresiz 73 öğe, `*WA0013*` → 2, `VID*0012*` → 2.

## İki dillilik

`L("türkçe", "english")` (bkz. `mac/Sources/AndrOSApp/L10n.swift`) çağrı
yerinde iki diziyi birden tutar. Ayrı `.lproj` paketleri tercih edilmedi:
uygulama SwiftPM ile derlenip elle paketlendiği için `.strings` dosyaları
derleme sırasında doğrulanmaz, eksik çeviri sessizce İngilizce anahtar
olarak görünürdü. Bu biçimde eksik çeviri **derlenmez**.

Dil seçimi `Locale.preferredLanguages`'e bakar; AndrOS ▸ Dil menüsünden
Otomatik / Türkçe / English olarak sabitlenebilir (`language` anahtarı).
Menüler anında, paneller yeniden başlatınca güncellenir.

## Menü çubuğu

`AndrOS · Düzen · Görünüm · [Yansıtma] · Pencere · Yardım`

**Yansıtma menüsü yalnız yansıtma penceresi odaktayken menü çubuğuna
girer.** `NSWindow.didBecomeKey/didResignKey` bildirimleri dinleniyor;
odak bir pencereden diğerine geçerken önce "resign" sonra "become" geldiği
için karar bir çalışma turu ertelenir, yoksa menü bir anlığına kaybolup
geri geliyor. İçindeki her şey (ana ekran, ses, güç tuşu, döndür, makro,
panel) yalnız o pencere için anlamlı olduğundan ana uygulama odaktayken
orada durması kafa karıştırırdı.

**Dock ve ⌘Tab macOS'ta aynı ayara bağlı** (`NSApplication.ActivationPolicy`).
`.accessory` hem Dock simgesini hem ⌘Tab kaydını kaldırır; "Dock'ta gizle
ama ⌘Tab'de kal" için desteklenen bir API yok. Varsayılan açık bırakıldı ve
takas menü öğesinin ipucunda yazıyor. Politika değişince AppKit açık
pencereleri arka plana atıyordu — kullanıcının gözünde pencere "kapanıyordu";
görünür pencereler not alınıp politikadan sonra geri getiriliyor.

## Küçük düzeltmeler

**Kaydırma yönü.** `scrollWrap` artık `TopClipView` (ters çevrilmiş
`NSClipView`) kullanıyor. AppKit'in varsayılanı ters koordinatta olduğu için
içerik gövdeden kısaysa alta yapışıyordu; pano geçmişi "en alttan
başlıyor" görünüyordu. Zaten ters olan gövdelerde (`NSTableView`,
`NSCollectionView`) `NSClipView.isFlipped` zaten `true` döndüğü için bu
değişiklik bir şeyi bozmuyor. Ölçüldü: en yeni pano kaydı y=240 (üstte),
en eski y=320.

**Sohbet konumu.** Mesajlar artık son mesajda açılıyor. Yükseklik ilk turda
kesinleşmediği için hem hemen hem bir sonraki döngüde kaydırılıyor.
Ölçüldü: ilk mesaj y=−5214, son mesaj y=741, görünür alan 230–753.

**İmleç.** Gömülü `AVPlayerView` artık `.inline`; `.floating` tam ekran için
tasarlandığından fare durunca imleci gizliyordu ve galeride video sekmesi
açıkken imleç kayboluyordu. Tam ekrana geçince `.floating`'e dönüyor,
çıkışta `NSCursor.unhide()`.

**Avatar.** Kişi baş harfi sabit yükseklikli `NSTextField` ile
çiziliyordu; AppKit metni hücrenin üstüne yasladığı için harf yukarıda
kalıyordu. `AvatarView` doğrudan çiziyor ve dikeyde **büyük harf
yüksekliğine** göre ortalıyor — satır kutusunu ortalamak 1,5 px aşağıda
bırakıyordu (ölçüldü). Kalan sapma ±0,5 px, tek pikselin altı.

## Cihazlar

`adb devices` yalnız o anda bağlı olanları verir. `DeviceRegistry`
(UserDefaults) bilinen cihazları kalıcı tutuyor: kablo çıkınca cihaz
listeden düşmüyor, "çevrimdışı" görünüyor; isim verilebiliyor, silinebiliyor.
Birden fazla cihaz bağlıyken `activeSerial` hangisinin kullanıldığını
belirliyor — eskiden her zaman listedeki ilki alınıyordu.

Kablosuz: `adb tcpip 5555` + cihazın IP'si ile `adb connect` ("Wi-Fi'yi aç",
cihaz USB'deyken). Android 11+ için `adb pair <adres> <kod>` da destekleniyor;
eşleştirme portunun bağlantı portundan farklı olduğu ekranda yazıyor.

## Yerinde yeniden adlandırma

`InlineEditLabel` (Finder'daki dosya adı gibi): normalde düz etiket,
`beginEditing()` ile kenarlık + imleç kazanır. Enter kaydeder, Esc vazgeçer,
odak kaybı kaydeder. Açılır pencere yerine bunu kullanmanın nedeni bağlamı
koparmaması ve fazladan tıklama getirmemesi. Cihazlar, Dosyalar ve Müzik
çalma listelerinde kullanılıyor; yeni çalma listesi de varsayılan adla
oluşup doğrudan düzenlemeye açılıyor.

Satır geri dönüştürüldüğü için "hangi satır düzenleniyor" bilgisi view
referansıyla değil **kimlikle** tutuluyor (`renamingID` / `renamingPath` /
`renamingPlaylist`).

## Tablo genişliği — ölçülen tuzak

Cihaz satırındaki sağa yaslı düğmeler kırpılıyordu. Ölçüm: görünür alan
236 px, sütun 230 px, **tablo 262 px**. Sebep: macOS 11+ `NSTableView.style`
varsayılanı (`.automatic` → `.inset`) tabloya her yandan 16 px iç boşluk
ekliyor. `style = .fullWidth` ile tablo 238'e indi ve taşma bitti.
Tabloya elle çerçeve vermek işi düzeltmiyor, ters yöne taşırıyor.

Ayrıca `selectionHighlightStyle = .none` seçilince AppKit
`drawSelection(in:)`'i **hiç çağırmıyor** — bu yüzden tıklayınca arka plan
değişmiyordu. `.regular` bırakılıp çizim `DeviceRowView`'da devralındı;
`interiorBackgroundStyle` `.normal` döndürülüyor, yoksa AppKit seçili
satırın etiketlerini beyaza çevirip soluk vurgunun üstünde okunmaz yapıyor.

## Kenar çubuğu görünümü

Kenar çubuğunu pencereden içerlek, dört köşesi yuvarlak bir "kart" yapmayı
denedik (macOS 26 görünümü). Sonuç zorlama duruyordu: trafik ışıklarının
konumu sistemden geliyor, kartın kenarlarıyla hizalanmıyor. Geri alındı —
kenar çubuğu pencere kenarına yapışık, köşesiz, `NSVisualEffectView`
`.sidebar` malzemesiyle; görünümü sisteme bırakıyoruz.

Kenar çubuğu daraltma düğmesi yığının içinden çıkarılıp **pencere
köküne**, trafik ışıklarının sağına (x=80, merkez y=16) alındı. Böylece
çubuk daralıp genişlerken düğme yerinden oynamıyor — Finder'ın kenar
çubuğu düğmesiyle aynı davranış. Pencere başlığı gizlendi, yoksa düğmeyle
üst üste biniyordu.

## ALT + tam ekran

Menü çubuğu artık gizlenmiyor (`presentationOptions = []`). Bu gerçek tam
ekran değil, pencereyi ekrana sığdıran bir büyütme; menü çubuğunu saklamak
hem "tam ekrandayım" yanılgısı yaratıyor hem de AndrOS'un kendi menülerini
erişilemez kılıyordu.

## Emülatör fizibilitesi (ölçüldü)

Bu makinede: `kern.hv_support = 1`, Intel i5-9400F, VMX bayrağı var,
175 GB boş. Yani Hypervisor.framework ile donanım hızlandırmalı x86_64
Android sistem imajı çalıştırılabilir. Android SDK kurulu değil.

## Emülatör

Kendi emülatörümüzü **yazmıyoruz**: Google'ın QEMU tabanlı `emulator`'ünü
indirip yöneten bir ön yüz var. Asıl kazanç şu — emülatör kendini adb'ye
normal bir cihaz gibi verdiği için AndrOS'un Yansıtma, Dosyalar, Galeri,
Uygulamalar ve Pano modülleri üzerinde **olduğu gibi** çalışıyor.

Ölçülen fizibilite (bu makine): `kern.hv_support = 1`, Intel i5-9400F,
VMX var → Hypervisor.framework ile donanım hızlandırma çalışır. Depo
taraması: Android 11–16'nın (API 30–36) hepsinde x86_64 imajı var, üç
varyantta (düz / Google APIs / Play Store).

Kurulum `~/Library/Application Support/AndrOS/android-sdk` altına yapılıyor,
SDK paket içinde dağıtılmıyor. Komut satırı araçlarının URL'i sabit
yazılmadı — sürüm numarası değiştikçe bağlantı kırılıyor; `repository2-3.xml`
çalışma zamanında taranıp mimariye uygun arşiv bulunuyor. Ölçülen kurulum
boyutu: 1.5 GB (cmdline-tools + platform-tools + emulator 37.1.11).

`config.ini` üzerinden ayarlananlar: RAM, çekirdek, VM yığını, dahili disk
(seyrek ayrılır — dosya kullanıldıkça büyür), SD kart, çözünürlük/yoğunluk,
GPU kipi (host/auto/swiftshader/angle/off), donanım hızlandırma, soğuk
başlatma, klavye geçirme, ön/arka kamera. Başlatma bayrakları en yüksek
başarım için: `-gpu <kip> -accel on -no-boot-anim -netdelay none -netspeed full`.

Sanal cihazlar listeleniyor, oluşturuluyor, **yerinde** yeniden
adlandırılıyor, klonlanıyor ve siliniyor. Klonlamada `.ini` ve `config.ini`
içindeki yol/kimlik alanları yeni ada göre yeniden yazılıyor.

Çekirdek katman UI dilini bilmediği için ilerleme ve hata **anahtarları**
(`pkg:emulator`, `tools.download`, …) yolluyor; metne panelde çevriliyor.

## Ölçülen tuzak: eksik `translatesAutoresizingMaskIntoConstraints`

Emülatör panelinde sağ sütunun tamamı bozuktu — düğmeler pencerenin dibine
inmişti. Sebep tek bir satırın eksikliğiydi: `statusLabel` için
`translatesAutoresizingMaskIntoConstraints = false` yazılmamıştı. Otomatik
boyut maskesi kısıtlara çevrilince yerleşim zinciriyle çakışıyor ve AppKit
**benim kısıtlarımı** kırıyor — hiçbir uyarı vermeden. Ölçüm: statusLabel
genişliği 2 px, konumu sol sütunda.

## Daraltılmış kenar çubuğu ve daraltma düğmesi

Daraltılmış genişlik trafik ışıklarına göre hesaplandı. Ölçüm: ışık grubu
62 px (3×16 + 2×7). 76 px genişlikte sol boşluk 11 px, sağ boşluk **3 px**
kalıyordu — kart yeşil düğmeye yapışıktı. 12 + 62 + 12 = **86 px** ile
iki yan eşitlendi.

Daraltma düğmesi trafik ışıklarının yanından **içerik başlığının soluna**
alındı. Işıkların yanındayken çubuk daralınca kartın kenarına biniyordu;
başlığın yanında hiçbir durumda çakışma yok, konumu tahmin edilebilir ve
içerik alanının araç çubuğu düğmesi gibi okunuyor.

## Sistem imajı varyantları

Her satırda ⓘ var (hover'da ipucu, tıklayınca açıklama):

- **AOSP (düz)** — Google Play Hizmetleri ve Play Store yok. En hafif,
  `adb root` açık.
- **Google APIs** — Play Hizmetleri var, Play Store yok. CTS sertifikası
  **yok**, `adb root` açık.
- **Play Store** — Play Store dahil ve **CTS sertifikalı**: Play Integrity /
  SafetyNet denetimini geçer, yani bankacılık uygulamaları ve mağaza
  korumalı oyunlar çalışır. Karşılığında `adb root` kapalı.

## Mobil uygulama (android/)

Amaç: **USB ya da kablosuz hata ayıklamaya gerek kalmadan** çalışmak.
Telefondaki uygulama bir ön plan hizmeti olarak TLS sunucusu açıyor,
kendini `_andros._tcp` olarak mDNS ile duyuruyor; Mac Bonjour ile
buluyor. USB de ayrı bir yol değil: USB bağlantı paylaşımı açıkken
Mac'e bir ağ arayüzü geliyor ve aynı duyuru oradan da görünüyor.

**Güvenlik.** Telefon anahtarını AndroidKeyStore'da üretiyor — özel
anahtar donanım destekli depodan hiç çıkmıyor. İlk eşleşmede telefon
ekranında 6 haneli kod beliriyor; Mac kodu doğrulayınca uzun ömürlü bir
belirteç alıyor ve **sertifika parmak izini sabitliyor**. Sonraki
bağlantılarda parmak izi birebir tutmazsa bağlantı reddediliyor.
Kod tek kullanımlık, 3 dakika ömürlü ve sabit süreli karşılaştırmayla
denetleniyor. Yetki alınmadan `hello` / `pair.begin` / `pair.confirm`
dışında hiçbir istek işlenmiyor.

**Çerçeve biçimi.** `[4 bayt uzunluk][1 bayt tür][gövde]`. Tür 0 = JSON
istek/yanıt/olay, tür 1 = ikili blok. Satır sonuyla ayırmak ikili veri
taşırken kaçış kuralları gerektiriyordu; uzunluk öneki ikisini de taşır.

**Neden uygulama gerekli.** Android 10'dan beri arka plandaki bir süreç
panoyu okuyamıyor; `adb` kabuğu da okuyamıyor, bu yüzden Mac'te pano
ancak yansıtma açıkken çalışıyordu. Arama kaydı sağlayıcısı da adb'ye
kapalı (`CallLogProvider · SecurityException`). Ön plan hizmeti ikisini
de çözüyor.

**Derleme.** `tools/android.sh` — Gradle ve SDK, AndrOS'un kendi destek
klasöründe (`~/Library/Application Support/AndrOS`), sistem geneline
kurulum yok. Ölçüldü: APK 5.6 MB, minSdk 26, targetSdk 36.

## Mobil uygulama — ölçülen tuzaklar

**`KeyStoreException: Incompatible digest`.** TLS el sıkışması sessizce
asılı kalıyordu. Sebep: anahtar `setDigests(SHA256, SHA512)` ile
üretilmişti, TLS başka bir özet seçince imza atılamıyordu. Tüm özetlere
(NONE, SHA1…SHA512) izin verildi. Ayrıca `KeyManagerFactory` depodaki
**tüm** anahtarları görüp ilkini seçtiği için eski kısıtlı anahtar hâlâ
kullanılıyordu; `ensureKey()` artık eski takma adları siliyor.
Doğrulandı: `TLSv1.3 / TLS_AES_256_GCM_SHA384 / ecdsa_secp256r1_sha256`.

**Rastgele port.** Sunucu her başlayışta `createServerSocket(0)` ile yeni
port alıyordu; mDNS kaydı bayatlayınca Mac eski porta bağlanıp
"connection refused" alıyordu. Sabit port **47821** (dolu ise rastgeleye
düşer).

**Geç gelen `reload()`.** Eşleştirme ekranı açıkken arka planda başlamış
cihaz sorgusunun yanıtı sağ sütunu eziyordu. `reload()` hem başlangıçta
hem de **tamamlanma bloğunda** kip kontrolü yapıyor.

**Doğrulanan uçtan uca akış:** Bonjour keşfi → TLS → `hello` (gerçek cihaz
bilgisi) → telefonda 6 haneli kod → `pair.confirm` → belirteç + sabitlenen
parmak izi kaydedildi.

## Emülatör — siyah ekranın sebebi

Ölçüldü: `hw.gpu.mode=angle_indirect` emülatörün kendi penceresini siyah
bırakıyor. `host` ve `swiftshader_indirect` sorunsuz açılıyor (60 sn'de
`sys.boot_completed=1`). Varsayılan `host` yapıldı.

**Penceresiz çalıştırma doğrulandı**: `-no-window -gpu host` ile açılıyor
ve gerçek GPU'yu kullanıyor. Emülatör adb'ye normal cihaz olarak
göründüğü ve scrcpy sunucusu üzerinde çalıştığı için, kendi yansıtma
hattımızla gösterilebilir — Android Studio'nun Qt penceresi yerine bizim
arayüzümüz ve panelimiz.

## Emülatör başarım ön ayarları

"Yüksek başarım ↔ yüksek kalite" tek eksende. Değerler makineye göre:
çekirdek başarımda yarısı, kalitede %75'i; RAM başarımda toplamın %37.5'i,
kalitede %50'si; VM yığını RAM'in sekizde biri (Android'in kendi cihaz
profillerindeki oran). Bu makinede (16 GB / 6 çekirdek) ölçülen çıktı:
başarım 3 çekirdek + 6144 MB, kalite 4 çekirdek + 8192 MB.

## Cihaza bağlı veriler

Çalma listeleri telefondaki dosya **yollarını** sakladığı için cihaz
başına ayrıldı (`musicPlaylists.<seri>`); başka cihazda o yollar yok,
liste yanıltıcı görünürdü.

## Cihaz birleştirme — ölçülen tuzak

Aynı telefon üç yoldan görünebiliyor: USB (adb), Wi-Fi (adb tcpip) ve
AndrOS uygulaması. Ayrı satırlar yanıltıcıydı; tek satırda birleştirip
`USB + Wi-Fi + AndrOS` etiketi gösteriliyor.

Birleştirme anahtarı olarak önce `Settings.Secure.ANDROID_ID` denendi ve
**çalışmadı**: Android 8'den beri uygulama başına farklı üretiliyor —
ölçüldü, uygulama `681bccdf…`, adb kabuğu `b90e4d66…`. Seri numarası da
Android 10'dan beri normal uygulamalara kapalı. Çözüm: uygulama kendi
kimliğini `/sdcard/Android/data/dev.naer.andros/files/andros-id`
dosyasına yazıyor, adb kabuğu oradan okuyabiliyor. Doğrulandı: liste
`RMX2040 → ● USB + AndrOS` olarak tek satır.

## QR ile eşleştirme

QR **Mac'te** gösteriliyor, telefon okuyor — çünkü Mac'te kamera yok,
telefonda var. Kullanıcı telefonun **kendi kamera uygulamasıyla** okuyor;
`andros://pair?c=…&n=…` derin bağlantısı AndrOS'u açıp kodu ön onaylıyor.
Böylece uygulamaya kamera/barkod kodu eklemeye gerek kalmıyor. Rakamlı
kutu yedek yol olarak duruyor.

## Bağlantı yolu seçimi

Hangi yolun hızlı olduğu ortama göre değişiyor: USB bağlantı paylaşımı
(RNDIS) çoğu telefonda sınırlı, iyi bir Wi-Fi daha hızlı olabilir; zayıf
sinyalde tersi. Tahmin etmek yerine **ölçülüyor**: `bench` ucu istenen
kadar veriyi ikili çerçevelerle akıtıyor, Mac bağlantıyı
`requiredInterfaceType` ile o yola zorlayıp gerçek MB/s ölçüyor. Sonuç
cihaz başına saklanıyor; "Otomatik" kipte hızlı olan seçiliyor,
kullanıcı isterse Wi-Fi ya da USB'yi sabitleyebiliyor.

## Mobil uygulama arayüzü

Mac ile aynı tasarım dili: koyu lacivert zemin (#0B1220), yumuşak köşeli
kartlar (18 dp), yeşil vurgu (#4ADE80). Üç kart — Bağlantı, Eşleştirme,
İzinler. İzinler tek tek listeleniyor, eksik olana dokununca isteniyor;
bildirim erişimi ve tüm dosyalara erişim normal izin diyaloguyla
verilemediği için ilgili sistem ekranına yönlendiriliyor.

## QR tarayıcı uygulamanın içinde

Önce QR'ı telefonun kendi kamera uygulamasının okuyup derin bağlantıyı
açması tasarlanmıştı. Kullanıcının telefonunda kamera uygulaması QR
okumuyor, bu yüzden tarayıcı **uygulamaya** eklendi
(`zxing-android-embedded` — ML Kit'e göre çok daha küçük ve Play
Hizmetleri gerektirmiyor). Derin bağlantı yolu da duruyor: okuyabilen
telefonlarda o da çalışır.

QR **Mac'te** gösterilir, telefon okur — Mac'te kamera yok. Doğrulandı:
QR `andros://pair?c=981232&n=Naer's Mac Pro` üretiyor ve ekrandan
okunabiliyor.

## Bayat Bonjour uç noktası

Telefon uygulaması yeniden başladığında Mac'in elindeki `NWEndpoint`
bayatlıyor ve bağlantı sonsuza kadar "connecting" durumunda asılı
kalıyor — ölçüldü: port açık, duyuru var, buna rağmen bağlanmıyor.
Eşleştirmeye girmeden önce tarama yeniden başlatılıyor.

## Eşleştirmedeki sonsuz döngü (saniyede onlarca QR + çökme)

Zincir şuydu: `connectCompanion` → tarayıcıyı yeniden başlat →
`browser.onChange` → `refreshList` → `applyFilter` seçimi programla
yeniden kur → `tableViewSelectionDidChange` → `connectCompanion`.
Tarayıcı geri çağrısı hızında dönüyor, her turda yeni QR üretiyor ve
uygulamayı düşürüyordu.

Dört ayrı koruma eklendi, hepsi tek başına yetersizdi:
1. Tarayıcı yeniden başlatma bağlanma yolundan **çıkarıldı**.
2. `connectCompanion` yeniden girişe karşı korumalı — aynı cihaza zaten
   bağlanıyor/bağlıysa hiçbir şey yapmaz.
3. `onState` aynı durumu **tekrar çizmez**.
4. Seçim programla kurulurken delege susturulur (`suppressSelection`).

## "Eşleştir" düğmesi — seçime güvenilemez

Eşleştirme satır seçimiyle başlatılıyordu. Liste tazelenirken ilk cihaz
kendiliğinden seçili kaldığı için, kullanıcı o satıra tıklayınca AppKit
hiçbir seçim değişikliği bildirmiyor ve **hiçbir şey olmuyordu**. Artık
sağ sütunda açık bir "Eşleştir" şeridi var. Ayrıca uygulama Bonjour ile
sonradan bulunduğunda şeridin belirmesi için, seçili cihazın eşleştirme
durumu değişince sağ sütun tazeleniyor.

## Kopya cihaz satırları

İşaret dosyası bir kez okunamayınca (uygulama henüz başlamamışken)
seri numarasına düşülüyor, o sonuç **önbelleğe alınıyordu** ve aynı
telefon hem kimlikle hem seriyle iki satır oluyordu. Artık başarısız
okuma önbelleğe alınmıyor. Eski `app:` anahtarları ve canlı bir cihazla
aynı adı taşıyan çevrimdışı kopyalar da kayıttan temizleniyor.

## Kalıcı bildirim

Ön plan bildirimi eşleşmeleri gösteriyor ve iki eylem taşıyor:
**Bağlantıyı kes** (oturumları kapatır, eşleşme kalır) ve
**Eşleşmeyi kaldır** (belirteçleri siler, bir dahaki sefere kod/QR
gerekir). Eşleşmeler `SharedPreferences`'ta olduğu için uygulama
kapansa da sürüyor. Doğrulandı: bildirimden eşleşme kaldırıldı,
Mac tarafı "not paired" durumuna döndü.

## Panellerin mobil uygulamaya bağlanması

`CompanionBridge`, asenkron `CompanionLink`'i **senkron** bir yüze
sarıyor. Paneller veri katmanını zaten arka plan kuyruklarından senkron
çağırdığı için (`AndroidData.contacts()` gibi), her paneli yeniden
yazmak yerine burada bekletiliyor — arayüz donmuyor.

`AndroidData.companion` doluysa modüller **önce onu** deniyor, yoksa
her şey eskisi gibi adb ile çalışıyor. Kazançlar:

| Modül | adb ile | Uygulama ile |
|---|---|---|
| Arama geçmişi | **imkânsız** (SecurityException) | çalışıyor |
| SMS gönderme | **imkânsız** (SEND_SMS yok) | gerçekten gönderiyor |
| Uygulama adları | yalnız paket adı | gerçek etiket |
| Uygulama simgeleri | APK açmak gerekiyordu | doğrudan PNG |
| Pano okuma | yalnız yansıtma açıkken | her zaman |

adb hiç yoksa ama uygulama eşleşmişse veri katmanı yine kuruluyor —
hedef zaten hata ayıklamasız çalışmak.

Doğrulandı: arama geçmişi gerçek kayıtlarla listelendi (ad, numara,
süre, yön ikonu); uygulamalar gerçek adlarıyla geldi ("Akbank",
"Asgardia" — paket adı değil).

**Eşleşme sonrası tetikleme.** Kalıcı bağlantı `AppDelegate`'te
kuruluyordu ama yalnız Bonjour listesi değişince. Eşleşme bittiğinde
`androsPaired` bildirimi yollanıyor, bağlantı hemen kuruluyor — yoksa
modüller bir sonraki ağ değişimine kadar uygulamayı kullanamıyordu.

**Erişilebilirlik.** "Eşleştir" düğmesi araç çubuğuna da kondu: sağ
sütundaki şerit kaydırma alanının içinde olduğu için erişilebilirlik
ağacından görünmüyor (VoiceOver de göremiyor).

## Sessizce düşen istekler — asıl kök sebep

"Genel olarak bağlanmıyor gibi", "Files gelmiyor", "Müzikler gelmiyor"
şikâyetlerinin tek bir sebebi vardı: `CompanionLink.request` bekleyen
geri çağrıyı `queue.async` ile kaydediyordu. Yanıt, geri çağrı sözlükte
yerini almadan gelebiliyor; `pending` boş olduğu için yanıt **sessizce
düşüyor** ve çağrı 20 saniye sonra zaman aşımına uğruyordu. Yarış
olduğu için bazen çalışıyor bazen çalışmıyordu — "bugluyor" tarifi
tam buydu.

İlk düzeltme (`queue.sync`) **daha kötüsünü** yaptı: `handshake()` zaten
`queue` üzerinde çalışan durum geri çağrısından `request()` çağırıyor,
aynı kuyruğa senkron girmek uygulamayı anında düşürdü. Doğrusu ayrı bir
`NSLock`. Ölçüm sonrası: Aramalar 429, Mesajlar 37, Dosyalar 24,
Uygulamalar 52 kayıt.

## Kategori kapıları

Cihaz yokken Pano ve Ekran Yansıtma açık kalıyordu (`default` dalına
düşüyorlardı). Artık cihaz yoksa veri gerektiren hiçbir kategori açık
değil ve açık olan kategori kapanırsa Cihazlar'a dönülüyor — boş beyaz
ekranda kalmak yerine.

## Eşleştirme kodunun ömrü

Kod her iki tarafta da **15 saniyede** yenileniyor ve kalan süre
%100'den %0'a inen bir çubukla gösteriliyor (rakamlı geri sayımdan daha
az dikkat istiyor, son üçte birinde turuncuya döner). Sonsuza kadar
geçerli bir kod güvenlik açığı; her yeniden çizimde yenilemek ise
telefonun okuduğu kodu geçersiz kılıyordu.

## Hız ölçümü — yanlış etiketleme

"Wi-Fi ölçülemedi, USB 6 MB/s" sonucu yanıltıcıydı: bu makinede ağ
bağlantısı **kablolu Ethernet**, Wi-Fi arayüzü hiç yok. Zorlanan
`.wiredEthernet` yolu USB sanılıyordu ama aslında LAN'dı. Artık
telefonun hangi arayüzlerden duyurulduğu adıyla gösteriliyor ve
gerçekten kullanılan yol ölçülüyor.

## Aramalar paneli

Yuvarlak köşeli vurgu (cihaz listesiyle aynı dil), açılışta seçili satır
yok, ve Samsung telefon yöneticisindeki gibi kaydırma hareketleri:
**sağa çek = ara**, **sola çek = mesaj yaz**. Sürükleme sırasında arkada
eylemin adı beliriyor ve eşik aşılınca renkleniyor; bırakınca satır
yumuşakça yerine dönüyor. Mesaj yolu, o kişiyle sohbeti açıyor; sohbet
yoksa yeni sohbet olarak hazırlıyor.

## Medya yolu — ölçülen tuzak

Galeri küçük resimleri ve görüntüleyici bozuktu. Sebep: mobil uygulama
`RELATIVE_PATH` döndürüyordu (`Android/media/.../WhatsApp Images/`),
Mac tarafı bunu dosya yolu sanıp çekmeye çalışıyordu — `/storage/
emulated/0/` öneki yok. Uygulama artık `MediaStore.MediaColumns.DATA`
ile **mutlak** yolu döndürüyor.

Ayrıca resim küçük resimleri de artık uygulamadan geliyor (256 px JPEG),
tam boy dosyayı çekmek yerine. Ölçüldü: 500 öğe hızlıca doldu.

## Panellerin geç gelen bağlantıya tepkisi

Panel açıldıktan **sonra** bağlantı hazır olabiliyor; eskiden panel boş
açılıp öyle kalıyor, ancak kategori değiştirip dönünce doluyordu. Müzik,
Galeri, Dosyalar, Uygulamalar ve Aramalar artık `androsRefresh`
bildirimini dinleyip kendiliğinden yeniden yüklüyor. Aramalar'da seçili
satır kimlikle saklanıp yenileme sonrası geri kuruluyor.

## Yansıtma penceresinin donuk dönmesi

Panelden kapatınca pencere yalnız `orderOut` ile gizleniyordu; nesne
ayakta kaldığı için ⌘⌥A ya da uygulamaya odaklanmak onu geri getiriyor,
oturum kapalı olduğundan donuk bir kare görünüyordu. Artık pencere,
görünüm ve içerik tamamen yıkılıyor; `focusWindow` da oturum yoksa ana
pencereye yönlendiriyor.

## Kategori titremesi ve pano uyarı yağmuru

**Titreme.** Yetenekler bağlantının *o andaki* `isReady` durumuna
bakıyordu. Bağlantı arada bir yeniden kuruluyor ve `isReady` kısa
süreliğine `false` oluyor; kategoriler (özellikle Aramalar) gri olup
geri geliyordu. Artık yetenekler **eşleştirme** durumuna bakıyor —
modül veriyi alamazsa zaten kendi boş durumunu gösteriyor, kategoriyi
kapatıp açmak kullanıcıyı şaşırtıyordu. Ayrıca köprü nesnesi bağlantı
anlık kopunca tamamen düşürülmüyor (`linkForData`): düşürülünce panel
adb'ye geçip listeyi boşaltıyordu. Ölçüldü: 40 saniye boyunca kesintisiz
etkin.

**Uyarı yağmuru.** Pano paneli telefonu 4 saniyede bir yokluyor;
uygulama hazır değilken bu, saniyede bir kipli uyarı açıp kategori
değiştirmeyi bile imkânsız kılıyordu. Otomatik yoklama artık **sessiz**;
uyarı yalnız kullanıcı "Telefondan al" düğmesine basınca çıkıyor.
Ölçüldü: Pano'da 20 saniye beklendi, hiç kipli pencere açılmadı,
kategoriler sorunsuz değişti.

## Tazelemeler kullanıcının işini bölmemeli

`UserBusy` ortak bir "şu an bir şey yapılıyor" bayrağı tutuyor. Arka
plandaki tazelemeler `UserBusy.run { … }` ile geçiyor: meşgulse
erteleniyor, iş bitince bir kez çalışıyor.

Bölünen işler ölçüldü: bir satırı sağa sola sürüklerken liste
yenilenince hareket yarıda kalıyordu; yerinde yeniden adlandırma kutusu
açıkken tazeleme satırı yeniden çizip yazıyı siliyordu. Bayrak ayrıca
fare basılıyken (`NSEvent.pressedMouseButtons`) kendiliğinden meşgul
sayıyor.

Bağlı yerler: kaydırma hareketi, satır içi yeniden adlandırma, Cihazlar
(6 sn), Emülatör (4 sn), cihaz taraması (3 sn) ve tüm panellerin
`androsRefresh` gözlemcileri.

## Görüntüleyici

Zemin **opak** yapıldı — yarı saydamken arkadaki ızgara görünüyor ve
kaydırılabiliyordu. Görüntüleyici açıkken ızgara tamamen gizleniyor.

İndirme artık **ilerleme çubuğuyla** ve iptal edilebilir
(`RawProcess.runStreaming` `adb pull`'un `[ 45%]` çıktısını okuyor).
Önceden büyük bir video sessizce iniyordu: kullanıcı çift tıklıyor,
hiçbir şey olmuyor sanıyor, sonra başka yere gezinirken oynatıcı birden
açılıyordu. Görüntüleyici kapatılırsa indirme iptal ediliyor.

## Çökme: koleksiyon görünümünde dizin taşması

Kilitlenme raporu `GalleryPanel.swift:482` — `Index out of range`.
AppKit, `items` değiştikten sonra ama `reloadData()` işlenmeden önce
eski indeksle hücre isteyebiliyor. Sınır kontrolü eklendi.

## Panellerin geç dolmasının üç sebebi

Yığın izinde aynı anda **birden fazla** `AndroidData.media` sorgusu
görünüyordu. Üç ayrı hata üst üste binmişti:

1. **Gözlemci birikmesi.** `androsRefresh` dinleyicisi `didAppear`
   içinde kaydediliyordu; `didAppear` her kategori geçişinde çağrıldığı
   için her dönüşte bir gözlemci daha ekleniyordu. Tek bir tazeleme
   bildirimi onlarca yükleme başlatıyordu. Artık bir kez kaydoluyor.

2. **Eşzamanlı yükleme.** Üst üste binen istekler adb'yi doyuruyor,
   uygulama köprüsünün istekleri arkada bekleyip 20 saniyelik zaman
   aşımına uğruyordu — panel dakikalarca boş kalıyor, sonra kendiliğinden
   doluyordu. Her panelde `isLoading` bayrağı var.

3. **Bayrak kilitlenmesi.** `isLoading` erken çıkışlarda ve
   `UserBusy` erteleme dalında sıfırlanmıyordu; ertelenen yükleme
   "zaten yükleniyor" sanıp dönüyor ve panel **kalıcı olarak** boş
   kalıyordu. Bayrak artık her durumda sıfırlanıyor.

Ölçüm sonrası: Aramalar 432 satır (ilk girişte ve tekrar girişte),
Mesajlar 37, Dosyalar 19, Uygulamalar 52 — hepsi 3–8 saniyede.

## Görüntüleyicide slayt gezinmesi

Araç çubuğunda önceki/sonraki düğmeleri; sol/sağ ok tuşları ve Esc de
çalışıyor. Resim ve video için aynı yol — hangi sekme açıksa onun
listesinde geziyor.

## Video akışı (indirmeden oynatma)

Mobil uygulamada küçük bir HTTP sunucusu var (`MediaServer`, sabit port
**47822**). `AVPlayer` byte-range destekli bir HTTP kaynağından akıtarak
oynatıyor — ilk saniyeler gelir gelmez başlıyor. Önceden dosya baştan
sona indiriliyordu; büyük videoda bu dakikalar sürüyor, kullanıcı çift
tıklayıp hiçbir şey olmadığını sanıyor, sonra başka yere gezerken
oynatıcı birden açılıyordu.

**Byte-range şart**: oynatıcının ileri sarması buna dayanıyor.
Güvenlik: yollar tek kullanımlık bir belirtecin arkasında — belirteci
bilmeyen (aynı ağdaki başka biri dahil) hiçbir dosyaya erişemiyor.
Akış kurulamazsa eski yola (indir-oynat, ilerleme çubuğuyla) düşülüyor.

## Slayt okları

Oklar araç çubuğunda değil **görüntünün sol/sağ kenarında**, dikeyde
ortalı, yarı saydam yuvarlak zeminde. Araç çubuğunda başlık yazısı yer
kapıp onları ekran dışına itiyordu; doğal yer de kenarlar. Sol/sağ ok
tuşları ve Esc de çalışıyor.

## Galeri kilitlenmesi (kendi eklediğim hata)

`isLoading` koruması Galeri'de **hiç sıfırlanmıyordu**. İlk yüklemeden
sonra bayrak kalıcı olarak `true` kaldığı için Resimler/Videolar sekme
değişimleri hiçbir şey yapmıyor, panel donmuş görünüyordu. Tamamlanma
bloğunda sıfırlanıyor. Ölçüm: Resimler 500 → Videolar 70 → Resimler 500.

## Kaydırarak gezinme

Ok düğmeleri kaldırıldı; görüntünün üzerini kapatıyorlardı. İki parmakla
yatay kaydırma önceki/sonraki öğeye geçiriyor (eşik 60 pt). Momentum
evresi yok sayılıyor — yoksa parmak kalktıktan sonra gelen artıklar üst
üste birkaç öğe birden atlıyordu. Ok tuşları ve Esc de çalışıyor.

## Arama — yapılabilenin sınırı

Ses Mac'e **taşınamıyor**, taşınabileceğini söylemek yanlış olurdu:
Android 10'dan beri `VOICE_CALL` ses kaynağı normal uygulamalara kapalı
(sistem izni `CAPTURE_AUDIO_OUTPUT` gerekiyor) ve telefonun giden ses
akışına dışarıdan ses vermenin API'si hiç yok. Root'suz bir cihazda
Mac'ten konuşmak mümkün değil.

Yapılan: aramayı Mac'ten **başlatmak** (`calls.dial`, `CALL_PHONE` izni
varsa doğrudan), arama geçmişinden **silmek** (tek tek ya da shift ile
çoklu), telefonun **kendi numarasını** okumak. Konuşma telefondan
yapılıyor; Mac arama başlayınca yerel bir bildirim gösteriyor.

## Bildirimler

Telefon bildirimleri Mac'e **anında** taşınıyor (olay olarak, sorulmasını
beklemeden) ve üç yerde görünüyor: Bildirimler kategorisi, macOS'un kendi
bildirim merkezi, ve bildirimin kendi eylemleri.

**Eylemler gerçek.** Bildirimin `Notification.Action`'ları olduğu gibi
taşınıyor; metin girdisi kabul edenler (WhatsApp, SMS) `RemoteInput` ile
doğrudan yanıtlanabiliyor. Kapatma telefonda da kapatıyor.

**Geçmiş ayrı tutuluyor**: telefonda kapatılan bildirim sistemden
siliniyor, ama kullanıcı bilgisayar başındayken neyi kaçırdığını
görebilmeli. Her iki liste de **en yeni en üstte** sıralanıyor —
Android'in verdiği sıra ekran yerleşimi, zaman sırası değil.

macOS bildirimi `.timeSensitive` seviyesinde: banner gibi kendiliğinden
kaybolmuyor, kullanıcı kapatana kadar duruyor.

## Süreci bildirim dinleyicisi ayağa kaldırıyor

Sistem, uygulama sürecini **bildirim dinleyicisini bağlamak için**
kaldırabiliyor; o yolda `MainActivity` hiç çalışmıyor ve sunucular
kurulmuyordu. Ölçüldü: süreç ayakta, bildirimler geliyor ama `onChange`
null ve portlar kapalı. `onListenerConnected` artık ön plan hizmetini de
başlatıyor — uygulama hangi yoldan ayağa kalkarsa kalksın bağlantı
kuruluyor.

## "Şimdi oynayan" ortak katmanı

Sol alttaki şerit yalnız `MusicEngine`'i dinliyordu; video açılınca orada
hiçbir şey görünmüyordu. `NowPlaying` ikisinin önünde duruyor: şerit
kimin çaldığını bilmeden aynı düğmelerle kontrol ediyor. Müzik
`AVAudioEngine`, video `AVPlayer` — tek motora indirmek yerine ortak bir
yüz verildi, böylece müzik tarafı hiç değişmedi. Videoda önceki/sonraki
10 sn geri / 30 sn ileri (tek video oynarken parça atlamak anlamsız).
Biri başlayınca diğeri susuyor.

## Telefon sunucusu: tek soket tum uygulamayi olduruyordu

`Server.serve()` icinde `raw.getInputStream()` cagrisi TLS el sikismasini
tetikliyor. Karsi taraf el sikismayi yarida birakinca
(`SSLHandshakeException: connection closed`) istisna `try` blogunun
DISINDA atiliyordu; `scope.launch` icindeki yakalanmamis istisna
Android'in varsayilan isleyicisine gidip **tum surec** kapatiliyordu.

Olculdu: bir `nc -z` port yoklamasi bile uygulamayi dusurdu. ColorOS
yeniden baslatmayi once 1,5 saniyeye, ikinci cokmeden sonra **30
dakikaya** erteledi — telefon "kapali" gorundu, Mac "uygulama gerekli"
dedi.

Cozum ucayakli:
- Akislari almak `try` icine alindi; el sikismasi bitmeden kopan
  baglanti sessizce kapatiliyor.
- Scope'a `CoroutineExceptionHandler` eklendi.
- `catch (e: Exception)` -> `catch (e: Throwable)`: bazi TLS hatalari
  `Error` olarak geliyor.

`MediaServer` de ayni tehlikedeydi: ham `thread {}` icinde yakalanmamis
`SocketException` (oynatici baglantiyi ortada keserse "broken pipe")
sureci kapatirdi. Simdi her istek kendi `try` blogunda.

## Kategoriler birbirini bekletiyordu

Telefon tarafinda istekler TEK SIRADA isleniyordu: galeri 500 kucuk
resim isterken arama gecmisi arkada bekliyor, Mac'teki 20 saniyelik
sure dolunca kategori bos donuyordu ("muzigi actim, Aramalar kayboldu").

Simdi yalniz GOVDESINI SOKETE AKITAN istekler (`files.read`, `bench`)
sirali; digerleri en fazla dorder paralel isleniyor. Yazma zaten
`synchronized(out)` ile atomik oldugu icin cerceveler karismiyor.

Mac tarafinda uc destek degisikligi:
- Yetenekler YAPISKAN (`stickyCaps`): bir kez gorulen yetenek ayni cihaz
  icin bir daha kapanmiyor. adb yoklamasi doygunlukta `false` donunce
  kategoriler griye donuyordu.
- `probe()` 3 saniyede bir degil, 60 saniyede bir.
- `getProp` onbellekli: `ro.*` degismiyor, ama her tazelemede birkac
  `adb shell` cagrisi galeri/muzik ile ayni siraya giriyordu.

## `isLoading` sifirlanmayinca panel oluyordu

`FilesPanel`, `AppsPanel` ve `MusicPanel` bayragi kurup hicbir yerde
sifirlamiyordu: ilk yuklemeden sonra `reload()` kalici olarak etkisiz
kaliyordu. "Klasor ekledim gelmedi, sildim etki etmedi" bunun sonucu.

## Serit (mini oynatici)

- `NowPlaying` oynaticiyi GUCLU tutuyor (once `weak` idi): goruntuleyici
  kapaninca `AVPlayer` cop toplaniyor ve video susuyordu. Artik galeri
  yalnizca gorunumden ayiriyor, oynatma seritte devam ediyor.
- Daraltilmis seritte (62 px is goren alan) dort dugme sigmiyordu;
  tasan dugmeler ebeveyn sinirinin disinda kaldigi icin TIKLANAMIYORDU.
  Dugmeler 18 px'e iniyor, kapatma dugmesi yalniz videoda gorunuyor.

## Kaydirma ile oge degistirme

`scrollWheel(with:)` gecersiz kilmak yetmedi: `AVPlayerView` olaylari
kendi yutuyor, `NSImageView` de hepsini ust gorunume vermiyor. Artik
goruntuleyici acikken yerel bir olay gozlemcisi calisiyor; hem trackpad
kaydirmasi hem FARE SURUKLEMESI her yerde isliyor. Fare olaylari
tuketilmiyor, boylece oynaticinin kendi denetimleri bozulmuyor.

`SwipeRow` da ayni sinifta bir sorundu: isim/ikon alt gorunumleri fareyi
kendi aliyordu, surukleme yalniz satirin BOS kisminda calisiyordu.
`hitTest` artik dugme olmayan alt gorunumlerin yerine satiri donduruyor;
satir secimi elle yapiliyor.

## Baslik hizasi

Trafik isiklari, daraltma dugmesi ve kategori adi ayni dikey merkezde.
Olcu sabit degil: `layoutTitlebarChrome()` her duzende gercek dugme
cercevesini okuyup kisiti guncelliyor. Baslik `centerYAnchor` ile degil
`firstBaselineAnchor` + `capHeight/2` ile baglandi — etiket kutusunun
merkezi alt kesme payi yuzunden harflerin merkezinden 1,5 px asagida
kaliyordu (olculdu).

## Telefonun ayakta kalmasi ("final boss")

Uc kilit, uc ayri sorun (`net/Keepalive.kt`):

- **Multicast kilidi** — Wi-Fi yongasi guc tasarrufunda multicast'i
  suzuyor. mDNS/Bonjour multicast; kilit olmadan telefon duyuruyu
  yayinlasa bile Mac goremiyor.
- **Wi-Fi kilidi (FULL_HIGH_PERF)** — ekran kapaninca yonga uykuya
  geciyor; yeni baglanti istekleri dusuyor.
- **Islemci kilidi (PARTIAL_WAKE_LOCK)** — yalniz BIR ISTEMCI
  BAGLIYKEN. Surekli tutmak pili bosuna yer.

`BootReceiver` acilis ve guncelleme sonrasi hizmeti geri getiriyor
(dogrulandi: `MY_PACKAGE_REPLACED` -> "hizmet yeniden baslatiliyor").
Pil eniyilestirmesi muafiyeti kullanici tarafindan verildi
(`dumpsys deviceidle whitelist` -> `user,dev.naer.andros`).

## Bulma: mDNS tek basina yetmiyor (olculdu)

Telefonun TLS portu acikken `dns-sd -B _andros._tcp` HICBIR SEY
dondurmedi. Olcum:

| hedef | sonuc |
|---|---|
| 192.168.1.143:47823 (tekil) | **cevap geldi** |
| 192.168.1.255 (alt ag yayini) | cevap yok |
| 255.255.255.255 (sinirli yayin) | cevap yok |

Yani bu agda yayin paketleri gecmiyor, tekil paketler geciyor. Bu
yuzden `UdpProbe` (Mac) + `UdpBeacon` (telefon, port 47823) ikilisi
soyle calisiyor: once yayin adresleri denenir, hicbir cihaz
bilinmiyorsa alt agin tamami TEKIL paketlerle taranir (254 kucuk paket,
bir saniyeden kisa). Cihaz bulununca yalniz bilinen adres yoklanir.
Paket ayni zamanda cihazi Doze'dan cikariyor — istenen "yerel
uyandirma" bu.

Dogrulandi: `UDP bulucu: RMX2040 @ 192.168.1.143:47821`, telefonda
"1 Mac bağlı".

Bulucu artik TEK ORNEK (`CompanionBrowser.shared`). Once uygulama ve
Cihazlar paneli ayri ayri kuruyordu: iki NWBrowser, iki alt ag taramasi.
Ayni kalip (paneli acinca bulucuyu yeniden baslatma) daha once sonsuz
eslestirme dongusune yol acmisti.

## `COLLATE LOCALIZED` tum baglantiyi dusuruyordu

`music.tracks` sorgusunda `ORDER BY title COLLATE LOCALIZED ASC`
kullaniliyordu. Android 11'den beri saglayici siralama ifadesini
denetliyor ve bu cihazda (ColorOS) reddediyor:
`Invalid token LOCALIZED`.

Atilan istisna yalniz o istegi degil, okuma dongusunun `catch`ine
dusup **TUM BAGLANTIYI** kapatiyordu. Yani "Muzik kategorisini actim,
Aramalar kayboldu" davranisinin telefon tarafindaki asil sebebi buydu —
Mac tarafindaki yetenek titremesi yalnizca ikinci katmandi. Ayni kalip
`ContactsModule`'de de vardi.

## Oncelik (QoS)

- Denetim baglantisi (Mac): `serviceClass = .responsiveData`, Nagle
  kapali. Kucuk JSON cerceveleri birlestirilmek icin bekletiliyordu.
- Denetim soketi (telefon): `tcpNoDelay`, `IPTOS_LOWDELAY`.
- Medya akisi (telefon): `IPTOS_THROUGHPUT` — video icin gecikme degil
  basarim onemli.
- Dosya aktarimi zaten TEK SIRADA (`TransferQueue.running`), yani akisi
  bogmuyor.

## Video: "geri gidilse de durmaz"

Kural: calan video ancak BASKA BIR VIDEO acilinca ya da seritteki
kapatma dugmesiyle durur. Geri tusu, sekme degistirme, resme gecme,
baska kategoriye gitme — hicbiri durdurmuyor; video muzik ya da
konusma iceriyor olabilir. Ayni video yeniden acilirsa bastan
baslamiyor, kaldigi saniyeden devam ediyor.

## Bildirimler Mac'e HIC ulasmiyordu — sessiz bir istisna

Telefon bildirimi goruyor, `onChange` doluydu, `broadcast` cagriliyordu
ve yine de Mac hicbir sey almiyordu. Sebep:

```
android.os.NetworkOnMainThreadException
  at ...Frame.writeJson(Protocol.kt:31)
  at ...Server$ClientLink.send(Server.kt:117)
  at ...Server.broadcast(Server.kt:110)
  at ...AndrOSService.onCreate$lambda$2(AndrOSService.kt:81)
```

`NotificationListenerService` geri cagrisi ANA IS PARCACIGINDA
calisiyor; Android oradan sokete yazmayi yasakliyor. Istisna
`ClientLink.send` icindeki BOS `catch` tarafindan yutuluyordu — ne hata
gorunuyordu ne bildirim geliyordu. `broadcast` artik IO kapsamina
gonderiyor, `catch` de istisnanin SINIFINI yaziyor.

Ders: bos `catch` bir hatayi yok etmiyor, yalnizca gorunmez yapiyor.

## Bonjour uc noktasi olu, dogrudan adres calisiyor

`NWConnection` cozumlenemeyen bir Bonjour hizmetine baglanirken hicbir
hata uretmeden "connecting" durumunda kaliyor; telefon tarafinda hic
baglanti gorunmuyor. Olculdu: her denemede 12 saniye bosa gidiyor,
sonra dogrudan adresle **0,37 saniyede** baglaniyor.

Uc onlem:
- `CompanionDevice.directEndpoint` — UDP yoklamasindan gelen ip:port.
  Varsa baglanti ONUNLA kuruluyor; duyuru bilgileri yine Bonjour'dan.
- 12 saniyelik zaman asimi: takili kalan baglanti kendini birakiyor.
- Bilinen adresler `UserDefaults`'ta saklaniyor ve bulucu ONLARLA
  basliyor — ilk deneme bile dogru yere gidiyor.

Ayrica `connectPairedCompanions` artik 20 saniyeden uzun sure
`connecting`/`awaitingCode` durumunda kalan baglantiyi da yeniliyor;
onceki kosul (`idle` ya da `failed`) takili baglantiyi hic
yakalamiyordu.

## Bildirim eylemleri iki tarafta da calisiyor

macOS banner'inda: **Yanitla** (metin kutusu, `UNTextInputNotification
Action`), **Okundu isaretle** (telefonda da kapatir), **Bu uygulamayi
sustur**. Kategori icinde ayni ucu, yanit kutusu SATIR ICINDE aciliyor —
acilir pencere yok.

Susturma YALNIZ Mac tarafini etkiliyor: telefonda bildirim gelmeye
devam ediyor ve kategoride gorunuyor, yalnizca banner cikmiyor.
Android'de ayri bir "okundu" kavrami olmadigi icin okundu = bildirimi
dusurmek. Telefonda kapatilan bildirim Mac'in bildirim merkezinden de
cekiliyor.

## Coklu cihaz

- Secim artik `(serial, companionId)` ikilisi tasiyor. Once yalnizca
  adb seri numarasi gonderiliyordu; sadece uygulamayla bagli bir telefon
  HIC secilemiyordu.
- `linkForData` etkin cihazin baglantisini tercih ediyor — birden fazla
  telefon eslesmisken panellerin hangisini gosterdigi rastgele degil.
- Calma listelerinin anahtari once uygulama kimligi: kablo takilip
  cikinca liste kaybolmuyor.
- Menu cubugunda **Cihaz** menusu: acik cihazlar ⌃⌘1…⌃⌘9 ile,
  etkin olan isaretli. Liste Cihazlar panelinin birlestirme mantigindan
  geliyor — ikinci bir kopya yok.

## Bildirim eylemleri: macOS'un iki kurali

1. **Ikiden fazla eylem katlaniyor.** Uc dugme kaydedince macOS hepsini
   tek bir "Secenekler" menusune topluyor ve kullanicinin once
   genisletme okuna basmasi gerekiyor — "Yanitla" gorunmuyordu
   (kullanici bildirdi, dogrulandi). Kategoriler artik EN FAZLA IKI
   eylem tasiyor: yanitlanabilir bildirimde `Yanitla + Okundu`,
   digerinde `Okundu + 1 saat sustur`.

2. **Dugmeler yalniz "Uyari" biciminde dogrudan gorunur.** Serit
   (banner) biciminde uzerine gelip genisletmek gerekiyor. Bu bir
   KULLANICI AYARI, uygulama degistiremiyor. Bildirimler panelinde tek
   seferlik bir oneri seridi var: bicimi olcup (`getNotificationSettings`
   -> `alertStyle`) serit ise "Ayarları aç" dugmesiyle dogrudan Sistem
   Ayarlari > Bildirimler'e goturuyor.

### Kategoriler uygulama basina

macOS'un ucnokta menusundeki "AndrOS'u sustur" ile bizim "Bu uygulamayi
sustur" eylemimiz karisiyordu. Artik her paket icin ayri kategori
uretiliyor (`andros.r.<paket>` / `andros.p.<paket>`) ve dugme yazisinda
GERCEK uygulama adi geciyor: "WhatsApp'ı 1 saat sustur". Kategori,
yeni bir uygulamadan ilk bildirim gelince kaydediliyor.

### Susturma sureli

Banner'daki dugme 1 SAAT susturuyor — "sustur" deyip kalici susturmak
kullaniciyi sasirtiyor. Kategorideki menude 1 saat / 8 saat / yarina
kadar / suresiz var, satirda kalan sure rozet olarak gorunuyor.
Susturma YALNIZ Mac'i etkiliyor: telefonda bildirim gelmeye devam
ediyor ve listede duruyor.

### Yanit sonrasi bildirim geri geliyordu

Cevap gonderilince mesajlasma uygulamasi kendi bildirimini
guncelliyor; bu yeni bir bildirim olayi olarak gelip ayni bildirimi
Mac'e geri getiriyordu. Iki onlem: yanittan sonra 12 saniyelik
sessizlik penceresi, ve yanit anlik banner'in kendisi geri cekiliyor
(is bitti).

Ayrica AYNI ICERIK tekrar uyarmiyor: mesajlasma uygulamalari tek mesaj
icin bildirimi birkac kez guncelliyor (olculdu: Discord ayni sohbet
icin saniyeler icinde uc kez) ve macOS her seferinde yeniden ses
cikariyordu.

## Bildirimin KENDI dugmeleri

Onceki surumde macOS banner'inda yalniz bizim uc eylemimiz vardi
(Yanitla / Okundu / Sustur). Telefondaki bildirimin kendi dugmeleri —
"Bağlantıyı kes", "Eşleşmeyi kaldır", "Duraklat", "Ertele" — yalnizca
kategoride gorunuyordu.

Artik kategoriler EYLEM KUMESI BASINA uretiliyor
(`andros.d.<paket+imza ozeti>`): bildirimin tasidigi butun dugmeler
banner'a oldugu gibi geciyor, sonlarina bizim "Okundu isaretle" ve
"<Uygulama> 1 saat sustur" ekleniyor. Kategori bildirim basina degil
kume basina uretildigi icin kayit listesi sinirsiz buyumuyor.

Dugme kimligi `andros.act.<sira>`; kullanici basinca `notifications.act`
ile TELEFONDAKI ayni eylem calisiyor. Metin kabul eden eylem
`UNTextInputNotificationAction` olarak geliyor, yani banner'dan
dogrudan yaziliyor.

DUGMELER KIRPILMIYOR. macOS ikiden fazlasini "Seçenekler" altina
katliyor; kullanicinin karari bu yonde oldu — bir tik uzakta ama
hicbir sey kaybolmuyor. Panelde zaten hepsi yan yana duruyor.

Surekli duran (`ongoing`) bildirimler macOS'ta banner OLMUYOR — AndrOS'un
kendi kalici bildirimi de dahil; onlarin dugmeleri Bildirimler
kategorisinde calisiyor.

## Yarim kalan TLS el sikismasi is parcacigi tutuyordu

Baglanti bir sure sonra hic kurulamaz oldu: portlar dinliyor, soketler
"established", ama el sikismasi bitmiyordu. Sebep: `getInputStream()`
el sikismasini tetikliyor ve karsi taraf yarida birakirsa SONSUZA KADAR
bekliyor. Her yarim kalan baglanti bir `Dispatchers.IO` is parcacigi
tutuyordu; varsayilan 64'luk havuz Mac'in tekrarlanan denemeleriyle
doldu. `soTimeout = 15 sn` (yalniz EL SIKISMASI icin; sonra sifirlaniyor)
sorunu kesti.

## Telefon = Mac'in ses aygiti

Uc parca:

1. **`mac/AudioDriver/AndrOSAudio.c`** — CoreAudio sunucu eklentisi
   (AudioServerPlugIn). Ses panelinde iki cihaz aciyor: "AndrOS · Telefon
   (Hoparlör)" ve "AndrOS · Telefon (Mikrofon)". macOS 12.3'ten beri
   kullanicidan yuklenen ses eklentileri icin desteklenen TEK yol bu;
   eski DAL/kext yollari kapali. `coreaudiod` paketi
   `/Library/Audio/Plug-Ins/HAL` altindan yukluyor, kurulum root
   gerektiriyor (`tools/audio-driver.sh install`).

2. **Paylasimli halka** (`AndrOSAudioShared.h`) — iki taraf ayni basligi
   kullaniyor ki birbirinden habersiz degismesinler. Ses geri cagrisi
   GERCEK ZAMANLI bir is parcaciginda calisiyor: orada kilit almak,
   bellek ayirmak ya da soket beklemek dogrudan ses kesilmesi demek. Bu
   yuzden eklenti yalnizca halkaya kopyaliyor.

3. **`AudioBridge.swift`** — ag tarafi. Halkayi 10 ms'de bir bosaltip
   telefona yolluyor, telefondan geleni halkaya yaziyor. Birikme olursa
   ESKI SES ATILIYOR: gecikmeyi buyutmektense kisa bir bosluk daha iyi.

Telefon tarafi **`AudioLink.kt`**, ayri bir TLS soketinde (47824):
`AudioTrack` ile caliyor, `AudioRecord` ile kaydediyor. AYRI SOKET
onemli — ses denetim kanalinin arkasinda beklerse cizilme oluyor.
Yetki ayni eslestirme belirteciyle: mikrofon ve hoparlor en hassas iki
uc, eslesmemis istemci ne alabiliyor ne verebiliyor.

Bicim 48 kHz / 16 bit. Cikis stereo; mikrofon MONO cunku telefonlarin
cogu MIC kaynagini stereo acmiyor — Mac tarafinda ikiye kopyalaniyor.

Cihazlar HER ZAMAN "canli" bildiriliyor. Uygulama kapaliyken
kaybolsalardi ses paneli titrer ve kullanicinin secimi baska bir cihaza
kacardi; simdi yalnizca sessizlik uretiyorlar.

### Kamera icin durum

Sanal kamera (her uygulamada gorunen) icin gereken **CMIOExtension** bir
sistem uzantisi ve normalde Developer ID imzasi + noterlik istiyor.
Bu makinede `systemextensionsctl developer on` calisti — yani imzasiz
uzanti yuklenebilir durumda. Yol acik, uzanti henuz yazilmadi.

## Ses surucusunu uygulama kendisi kuruyor

Surucu artik uygulama paketinin icinde geliyor
(`Contents/Resources/AndrOSAudio.driver`) ve kurulumu `AudioDriver
Installer` yapiyor: macOS'un KENDI parola penceresi cikiyor, kullanici
Terminal'e gitmiyor. Kaynaktan derleme gerekmiyor — acik kaynak surumu
indiren herkeste calisir.

Neden `do shell script … with administrator privileges`: imzasiz bir
uygulamanin kullanabilecegi tek desteklenen yol. `SMJobBless` Developer
ID imzasi istiyor, `AuthorizationExecuteWithPrivileges` kaldirildi.
Paketle gelen surum kuruludan yeniyse guncelleme oneriliyor.

## Telefonun kendi sesi -> Mac (yansitmasiz)

"Kulaklikta iki cihaz bagliymis gibi": Mac'te calisirken telefona gelen
bildirim/muzik sesi ayni kulakliktan duyulsun.

Android 10'dan beri bunun yolu `AudioPlaybackCapture` ve yalnizca
`MediaProjection` izniyle aciliyor. EKRAN PAYLASILMIYOR — izin sadece
ses yakalamanin kapisi, Android baska yol vermiyor. Onay telefondan
alinmak zorunda (sistem diyalogu), bu yuzden anahtar telefon
uygulamasinda: "Telefon sesini Mac'e ver".

Iki SINIR Android'in kendi kurali:
- Uygulamalar kendilerini yakalamaya kapatabiliyor
  (`allowAudioPlaybackCapture=false`).
- GORUSME sesi (`USAGE_VOICE_COMMUNICATION`) hicbir kosulda
  yakalanamiyor.

Gelen ses sanal aygittan DEGIL, Mac'in su anki cikisindan caliniyor
(`AudioPlayer`): amac kullanicinin Mac kulakligiyla telefon bildirimini
de duymasi.

## Mikrofon calismiyordu: izin hic istenmiyordu

`RECORD_AUDIO` manifeste eklenmisti ama calisma zamani izin listesinde
yoktu; olculdu: `granted=false`. Ses kanali aciliyor, yetki geciyor,
kayit hic baslamiyordu ("mikrofon izni yok"). Izin artik telefon
uygulamasindaki listede — kullanici bir kez onaylayinca calisiyor.
`adb shell pm grant` ile disaridan verilemiyor (ColorOS reddediyor),
onay kullanicidan gelmek zorunda.

## Ses yollari cakismasin

Uc yol ayni telefonun sesine dokunuyor: yansitma (scrcpy), ses koprusu
ve sanal aygit. `AudioRouting` tek karar noktasi.

**Geri besleme dongusu** en tehlikelisiydi: telefonun sesi Mac'te
calinirken Mac'in cikisi "AndrOS Hoparlör" ise ses telefona geri gider
ve dongu olusur —

    telefon sesi -> Mac -> AndrOS Hoparlör -> telefon -> ...

Bu yuzden telefon sesi HICBIR KOSULDA sanal aygitimizdan calmiyor:
`deviceForPhoneAudio()` varsayilan cikis bizimse ilk fiziksel cikisa
duserek sesi yine de duyuruyor. Hem koprii hem yansitma oynaticisi bu
aygiti kullaniyor.

**Cift ses**: yansitma sesi acilinca koprii telefon sesini yakalamayi
birakiyor (Mac'ten `KIND_CAPTURE_PAUSE`), kapaninca geri aliyor. Ayni
ses iki yoldan gelmiyor.

## Kamera

Zincir: telefon Camera2 -> `MediaCodec` H.264 -> ayri TLS soketi (47825)
-> Mac `VideoDecoder` (VideoToolbox) -> kareler.

Ham kare gondermek mumkun degil (1080p30 YUV ~750 Mbps). 720p ve 6 Mbps
secildi: webcam icin fazlasi gorunur bir sey katmiyor. Anahtar kare
araligi 1 sn — Mac gec baglansa da goruntu hemen oturuyor.

### "Camera disabled by policy" — servisin nereden baslatildigi

Kamera acilmiyordu: `Camera "0" disabled by policy`. Sebep Android'in
kurali: **ARKA PLANDAN baslatilan on plan hizmetine kamera ve mikrofon
erisimi verilmiyor.** Logda 15 kez `Foreground service started from
background can not have location/camera/microphone access` vardi —
hizmet acilista/bildirim dinleyicisinden basladigi icin yetkisiz
kaliyordu.

Cozum: `AndrOSService.startedFromForeground` bayragi. Kullanici telefon
uygulamasini actiginda hizmet arka plandan baslamissa ON PLANDAN
yeniden kuruluyor ve yetki geliyor. Dogrulandi: yeniden kurulumdan
sonra `CONNECT device 0 client for package dev.naer.andros`, Mac
tarafinda `kamera: 1280x720 (arka)`.

Telefon acamadiginda SEBEBI yolluyor (`policy` / `inuse` /
`permission`) ve Mac kullaniciya ne yapmasi gerektigini yaziyor —
sessizce basarisiz olmuyor.

### Menu cubugu onizlemesi

Kamera akiyorken menu cubugunda CANLI kucuk goruntu duruyor: kameranin
acik oldugu her zaman gorunur olmali. Saniyede 5 kare — ikon 22 px,
daha sik cizmek gorunur bir sey katmiyor ama islemci yiyor. Tiklayinca
on/arka degistirme ve kapatma.

### Kalan: sanal kamera uzantisi

`VirtualCamera` su an gecis: kareler geliyor ama sisteme sunulmuyor.
Her uygulamada gorunmesi icin CMIOExtension gerekiyor (bu makinede
`systemextensionsctl developer on` ile imzasiz yuklenebilir). Efektler
de ayni yerde uygulanacak — sanal kameraya, uygulama ici onizlemeye
degil; amac kamerayi kullanan HER programda ayni goruntunun cikmasi.

## Sanal kamera uzantisi: kum havuzu + uygulama grubu sart

`OSSystemExtensionManager` etkinlestirmesi once **kod 9
(validationFailed) — "extension category returned error"** ile
reddedildi. Denenenler ve sonuc:

| uzantinin hak talepleri | sonuc |
|---|---|
| `app-sandbox` YOK, `get-task-allow` | kod 9, CMIO reddetti |
| `app-sandbox` + `application-groups = [dev.naer.andros.camera]` | **kabul** |

Yani CMIO kategorisi uzantinin KUM HAVUZUNDA olmasini ve
`CMIOExtensionMachServiceName` degerinin uzantinin bir UYGULAMA
GRUBUNDA bulunmasini istiyor. Apple'in ornegi bunlari takim kimligi
onekiyle yaziyor; imzasiz (ad-hoc) surumde takim kimligi olmadigi icin
grup adi dogrudan paket kimligi — ve bu makinede kabul edildi.

Dogrulandi:

    systemextensionsctl list
    *  *  -  dev.naer.andros.camera (1.0/1)  AndrOS Kamera  [activated enabled]

    system_profiler SPCameraDataType
    AndrOS · Telefon Kamerası   Model ID: AndrOS

Yani kamera artik SISTEM GENELINDE bir aygit: FaceTime, Zoom, Photo
Booth gibi kamera kullanan her uygulama goruyor.

Imzasiz kurulum icin `systemextensionsctl developer on` gerekiyor.
Notere gonderilmis bir surumde bu gerekmiyor; acik kaynak surumu icin
README'ye yazilacak.

### Kareler

Uzanti kareleri paylasimli bellekten aliyor (`AndrOSCameraShared`,
NV12, uc slot, artan sira numarasi). Sirayi EN SON artiriyoruz ki
uzanti yarim yazilmis slotu okumasin. Uygulama kare uretmiyorsa uzanti
duz gri veriyor — kamera "bozuk" gorunmesin.

Efektler menu cubugundaki kamera ogesinde: kamera acikken bakilan yer
orasi. Efekt sanal kameraya uygulaniyor, yani kamerayi kullanan HER
uygulamada gorunuyor.

## Sanal kameraya kare vermek: paylasimli bellek CALISMIYOR

Ses tarafinda ise yarayan POSIX paylasimli bellek burada ise yaramadi.
Sebep: CMIO uzantinin KUM HAVUZUNDA olmasini sart kosuyor ve kum
havuzundaki bir surecte POSIX paylasimli bellek adi kendi kabina
esleniyor. Uygulama kum havuzunda olmadigi icin ayni adi acsa bile
BASKA bir bellege bakiyor.

Olculdu: uygulama "kareler akiyor" diyor, uzanti ise hep yer tutucu
gonderiyordu (`camtest`: Y min=96 max=128 — yani duz desen).

Dogru gecit CMIO'nun kendi **sink akisi**: cihazda ikinci bir akis var,
uygulama oraya kare koyuyor, uzanti `consumeSampleBuffer` ile cekip
kaynak akisa aktariyor.

### Yon degerleri ters okunuyordu

Sink akisini `kCMIOStreamPropertyDirection == 1` diye ariyordum. Gercek
olcum:

    akış 37  yön=1  ad=AndrOS Kamera   (kaynak — uygulamalarin okudugu)
    akış 38  yön=0  ad=AndrOS Giriş    (sink  — bizim yazdigimiz)

Yani yon CIHAZIN bakis acisindan. Yanlis akisi actigim icin uzantinin
sink `startStream`i hic cagrilmiyordu; `CMIODeviceStartStream` yine de
`noErr` donuyordu — sessiz basarisizlik.

Duzeltme sonrasi dogrulandi:

    uzanti: "sink akisi basladi" -> "sink: ilk kare alindi"
    camtest: Y min=39 max=155 (gercek goruntu), 30 fps

## Cozucuye SPS/PPS verilmiyordu

`VideoDecoder.decode()` yalnizca oturum kurulmussa is goruyor; oturumu
kuran sey `setParameterSets()`. `CameraBridge` her paketi dogrudan
`decode()`'a veriyordu, dolayisiyla `MediaCodec`'in ayri gonderdigi
"codec config" tamponu (SPS+PPS) hicbir zaman islenmiyordu. Sonuc:
paketler geliyor, hicbir kare cozulmuyor — hem de sessizce.

Olculdu: `60 paket geldi ama HİÇ kare çözülemedi`. Artik her paketin
NAL turleri taraniyor; SPS/PPS varsa once oturum kuruluyor.

## Kamera degistirmede "error2"

`CameraDevice.close()` es zamanli degil. Kapanma bitmeden yeni kamerayi
acmaya calisinca `ERROR_MAX_CAMERAS_IN_USE` (2) geliyordu. Artik
`onClosed` bekleniyor (en fazla 1,5 sn), sonra aciliyor.

## Menu cubugu: menu degil DENETIM PANELI

Gunluk kullanilan seyler (telefonu ses aygiti yapmak, mikrofon, kamera)
ana pencerede kucuk kutucuklar halindeydi: bulunmasi zordu ve dar
pencerede sigmiyordu. Hepsi menu cubugundaki panele tasindi
(`StatusPanel`): ustte cihaz ve durum, altinda uc anahtar — her birinin
NE YAPTIGI tek satirda yazili — sonra yansitma/pencere kisayollari,
kategori dugmeleri ve cikis.

Kamera simgesi ayri bir oge ve tiklayinca MINI OYNATICI aciyor
(`CameraPanel`): 320x180 canli onizleme, altinda on/arka ve 90° donus,
ayri bir bolumde efekt listesi. Menu cubugundaki 20 px'lik gomulu
goruntu "acik mi?" sorusunu yanitliyor; bakilacak yer bu panel.

`.transient` popover LSUIElement uygulamasinda acilir acilmaz odagi
kaybedip kendini kapatiyor; bu yuzden gostermeden once
`NSApp.activate(ignoringOtherApps:)` cagriliyor.

### Donus efektten AYRI

Efekt bir "gorunum" secimi, donus ise duzeltme: telefon yan tutulunca
goruntu yatiyor. `VirtualCamera.rotation` 0/90/180/270 arasinda donuyor
ve efektle TEK GECISTE uygulaniyor — 30 fps'te iki ayri kopya cikarmak
gereksiz is.

### Istemciler icin uc bicim

Tek 720p bicim veren cihazi bazi istemciler (tarayicilar, Electron
uygulamalari) eliyor: varsayilan 640x480 istiyorlar ve pazarlik
basarisiz olunca kamerayi hic gostermiyorlar. Ayni tampondan
1280x720 / 640x480 / 320x240 sunuluyor.

## Menu cubugu popover'lari: odak ve kapanma

`.transient` popover, menu cubugu uygulamasinda (LSUIElement) acilirken
odagi almiyordu; disariya tiklayinca odagini kaybediyor ama KAPANMIYOR,
ekranda tiklamayi yemeyen bir kutu kaliyordu.

`PopoverHost` uc parcayla cozuyor: gostermeden once uygulamayi one
getirmek, popover penceresini ANAHTAR yapmak (yoksa ic denetimler ilk
tiklamayi yiyor) ve disari tiklamayi kendimiz dinleyip kapatmak — biri
global gozlemci (baska uygulamalar), biri yerel (kendi pencerelerimiz).

## Aynalama efektten AYRI

Aynalama efekt listesinde bir secenek olarak durunca "siyah beyaz +
ayna" yapilamiyordu; biri otekini kapatiyordu. Aynalama bir gorunum
tercihi degil, donus gibi bir yon duzeltmesi — kendi anahtari var ve
efektle birlikte calisiyor.

Onizleme artik ISLENMIS kareyi gosteriyor (`VirtualCamera.onProcessed`):
efekt/donus/ayna ayarinin etkisi menu cubugu panelinde de goruluyor.
Menu cubugu simgesi sabit: 20 px'lik gomulu canli goruntu ne oldugu
anlasilmadan huzursuz duruyordu.

## Kopan baglanti hata degil

"Connection reset by peer" (POSIX 54) olagan: telefon uykuya gecer, ag
degisir, karsi taraf soketi kapatir. Kullaniciya hata gostermek yerine
3 saniye sonra sessizce yeniden baglaniliyor — hem kamera hem ses
koprusu icin. Kullaniciya YALNIZ telefonun acikca soyledigi sebepler
gosteriliyor (izin yok, kamerayi baska uygulama kullaniyor).

## Web sitesi (ayri, OZEL depo)

`nFluDev/andros-web` — private. Acik kaynak depoya sizmasin diye
AndrOS'un `.gitignore`'una `web/` eklendi.

Tek nginx kabi: statik sayfalar + `/api/releases` icin onbellekli
gecis. Uygulama kodu yok.

**Host portu YAYINLANMIYOR.** Dokploy'da ters vekil kaba Docker agi
uzerinden ulasiyor; host portu acmak yalnizca cakisma uretiyor —
olculdu: `Bind for 0.0.0.0:8080 failed: port is already allocated`.
Yerel deneme icin ayri bir `docker-compose.local.yml` var.

Iki tuzak daha kapatildi:
- Onbellek dizini icin adlandirilmis birim (named volume) kaldirildi:
  baglanan birim root'a ait oluyor ve nginx isci sureci oraya yazamiyor.
- `proxy_pass`taki sorgu dizesi kaldirildi; nginx istegin kendi
  argumanlarini da ekleyebiliyor.

Indirme baglantilari ve degisiklik gunlugu **GitHub Releases**'ten
okunuyor. Elle guncellenen bir surum numarasi er ya da gec yanlis olur.
GitHub cevap vermezse nginx ESKI kopyayi veriyor — "surum bilgisi yok"
demesindense bayat bilgi iyidir.

## Android ayarlari

Her satirin ALTINDA ne yaptigi yaziyor. Bir anahtarin ne anlama
geldigini tahmin ettirmek, kullaniciyi ya korkutup hic dokundurmuyor ya
da yanlislikla actiriyor.

Uc bolum: baslangic/arka plan, guncelleme, sifirlama.

### Kalici bildirim KALDIRILAMIYOR

Android on plan hizmetinin bildirimini zorunlu tutuyor. Yapilabilecek
tek sey onceligi dusurmek — ama bir kanalin onceligi OLUSTURULDUKTAN
SONRA degistirilemiyor, bu yuzden IKI kanal var: normal (LOW) ve
sessiz (MIN). "Sessiz bildirim" acikken bildirim golgesinin dibinde,
sessiz ve rozetsiz duruyor. Ayarda bu acikca yaziyor.

### Simgeyi gizleme

`setComponentEnabledSetting` ile baslatici simgesi kapatilabiliyor;
uygulama cekmecede gorunmez oluyor. Geri getirmek icin Mac'ten bir yol
gerekiyor — ayarda bu uyari veriliyor, yoksa kullanici uygulamayi
kaybediyor.

### Guncelleme

Kaynak GitHub Releases (site ile ayni). SESSIZ KURULUM YOK: Android
buna izin vermiyor ve vermemeli de. Kullaniciya haber verilip APK
indiriliyor, kurulumu o onayliyor. Surum karsilastirmasi SAYISAL —
metin karsilastirmasi "1.10 < 1.9" der.

## macOS ayarlari

Pencerenin sag alt kosesindeki disliden aciliyor — icerik kutusuyla
AYNI ic bosluklarda, kenara yapisik degil. Popover olarak beliriyor;
bu boyuttaki bir ayar kumesi icin ayri pencere fazla.

Uc bolum: Genel (giriste baslat, otomatik guncelleme), Menu Cubugu
(yansitma yonetimi, oynatici, kamera simgesi, telefon etkinlikleri),
Bakim (telefona kur, guncelleme denetle, onbellek temizle, sifirla).
Her satirin altinda ne yaptigi yaziyor.

Menu cubugu anahtarlari `androsSettingsChanged` ile hemen etki ediyor:
kapatilan sey o anda kayboluyor, uygulamayi yeniden baslatmak gerekmiyor.

**Giriste baslat** `SMAppService.mainApp` ile — macOS 13'ten beri
kullanicidan izin istemiyor; eski LaunchAgent plist yazma yolu artik
gereksiz.

**Telefona kur** karekodu `andros.gamehost.dev/install` adresini
gosteriyor; uretici uygulamadaki eslestirme karekodunun ayni
(CoreImage).

## Site 502 veriyordu: port

Dokploy'da alan adi baglanirken port bos birakilinca varsayilan
**3000**'e gidiyor; kap yalnizca 80'de dinledigi icin `502 Bad Gateway`
aliniyordu. nginx artik ikisini de dinliyor — kabin icinde ek maliyeti
yok ve hangi degeri verirsen ver calisiyor.
