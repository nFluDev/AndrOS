# vendor/scrcpy-server

Faz 1 taşıyıcısı. scrcpy sunucusu (Apache-2.0, Genymobile/scrcpy).
Cihazda shell UID altında `app_process` ile çalışır; ekran yakalama ve
girdi enjeksiyonu yapar.

`VERSION` dosyasındaki değer sunucuya birebir aynı geçilmek ZORUNDA —
uyuşmazsa sunucu kendini kapatır. Jar'ı güncellerken VERSION'ı da güncelle.

Buraya kopyalanmasının sebebi: sistemdeki scrcpy kurulumuna ve onun
sürümüne bağımlı kalmamak.
