//
//  AndrOSAudioShared.h — surucu ile uygulama arasindaki ORTAK sozlesme.
//
//  Ses surucusu `coreaudiod` icinde (root olarak), koprii ise AndrOS
//  uygulamasinda (kullanici olarak) calisiyor. Ikisi arasinda POSIX
//  paylasimli bellek uzerinde iki halka tampon var:
//
//    out : Mac'in caldigi ses  -> telefona gider (telefon hoparloru/kulaklik)
//    in  : telefonun mikrofonu -> Mac'e gelir
//
//  Neden paylasimli bellek: ses geri cagrisi GERCEK ZAMANLI bir is
//  parcaciginda calisiyor; orada kilit almak, bellek ayirmak ya da
//  soket beklemek ses kesilmesi (dropout) demek. Halka tamponda
//  yalnizca atomik sayac okuma/yazma var.
//
#ifndef ANDROS_AUDIO_SHARED_H
#define ANDROS_AUDIO_SHARED_H

#include <stdint.h>

#define ANDROS_SHM_NAME     "/andros.audio.v1"
#define ANDROS_MAGIC        0x414E4452u          /* 'ANDR' */
#define ANDROS_VERSION      1u

#define ANDROS_RATE         48000
#define ANDROS_CHANNELS     2
/* Bir saniyelik pay: ag dalgalanmasini yutacak kadar buyuk, gecikmeyi
   hissettirmeyecek kadar kucuk. Koprii tamponu ~40 ms dolulukta tutuyor. */
#define ANDROS_RING_FRAMES  48000
#define ANDROS_RING_SAMPLES (ANDROS_RING_FRAMES * ANDROS_CHANNELS)

typedef struct {
    uint32_t magic;
    uint32_t version;

    /* Kare cinsinden kosan sayaclar; sarma islemi indekste yapiliyor. */
    volatile uint64_t outWrite;   /* surucu yazar  */
    volatile uint64_t outRead;    /* koprii okur   */
    volatile uint64_t inWrite;    /* koprii yazar  */
    volatile uint64_t inRead;     /* surucu okur   */

    volatile uint32_t outRunning; /* cikis akisi acik mi */
    volatile uint32_t inRunning;  /* giris akisi acik mi */
    /* Koprunun canlilik damgasi (Unix saniyesi). Uygulama kapaliyken
       surucu sessizlik uretiyor ama CIHAZLAR KAYBOLMUYOR — ses paneli
       her acilis kapanista titremesin. */
    volatile uint64_t bridgeHeartbeat;

    float out[ANDROS_RING_SAMPLES];
    float in[ANDROS_RING_SAMPLES];
} AndrOSAudioShared;

#endif /* ANDROS_AUDIO_SHARED_H */
