//
//  AndrOSCameraShared.h — uygulama ile kamera uzantisi arasindaki sozlesme.
//
//  Uzanti AYRI BIR SURECTE calisiyor (sistem baslatiyor) ve kareleri
//  bizden almak zorunda. Ses tarafindaki halka tamponun ayni fikri:
//  paylasimli bellekte birkac slot ve artan bir sira numarasi.
//
//  Bicim NV12 (420YpCbCr8BiPlanar): cozucunun (VideoToolbox) dogal
//  cikisi bu, kameralar da bunu kullaniyor — arada donusum yok.
//
#ifndef ANDROS_CAMERA_SHARED_H
#define ANDROS_CAMERA_SHARED_H

#include <stdint.h>

/* KUM HAVUZU KURALI: uzanti kum havuzunda calisiyor (CMIO boyle
   istiyor) ve orada POSIX paylasimli bellek adi UYGULAMA GRUBU
   kimligiyle BASLAMAK zorunda. Ad bu yuzden duz "andros.camera" degil.
   Uygulama kum havuzunda olmadigi icin ayni adi sorunsuz aciyor. */
#define ANDROS_CAM_SHM      "/dev.naer.andros.camera.v1"
#define ANDROS_CAM_MAGIC    0x414E4443u        /* 'ANDC' */
#define ANDROS_CAM_VERSION  1u

/* Ust sinir: 720p. Daha buyugu webcam icin gorunur bir sey katmiyor,
   bellek ve bant genisligi ise hizla buyuyor. */
#define ANDROS_CAM_MAXW     1280
#define ANDROS_CAM_MAXH     720
#define ANDROS_CAM_FRAME    (ANDROS_CAM_MAXW * ANDROS_CAM_MAXH * 3 / 2)
/* Uc slot: yazan ile okuyan ayni slotta bulusmasin. */
#define ANDROS_CAM_SLOTS    3

typedef struct {
    uint32_t magic;
    uint32_t version;
    volatile uint32_t width;
    volatile uint32_t height;
    /* Yazilan kare sayisi. Son kare: (sequence - 1) % SLOTS */
    volatile uint64_t sequence;
    /* Uygulama kare uretiyor mu (0 ise uzanti kapali goruntu verir). */
    volatile uint32_t running;
    uint32_t _pad;
    volatile uint64_t heartbeat;
    uint8_t frames[ANDROS_CAM_SLOTS][ANDROS_CAM_FRAME];
} AndrOSCameraShared;

#endif
