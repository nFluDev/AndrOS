//
//  Swift'in dogrudan cagiramadigi C parcalari.
//
//  • `shm_open` degisken argumanli oldugu icin Swift'e aktarilmiyor.
//  • Sabit boyutlu C dizileri (`float out[...]`) yapinin uyesi olarak
//    Swift'e gelmiyor; isaretcilerini burada veriyoruz.
//
#ifndef ANDROS_AUDIO_SHIM_H
#define ANDROS_AUDIO_SHIM_H

#include "AndrOSAudioShared.h"

/// Surucunun actigi paylasimli halkayi baglar. Yoksa NULL.
AndrOSAudioShared* androsAudioAttach(void);
void  androsAudioDetach(AndrOSAudioShared* p);
/// Cikis halkasi (Mac -> telefon).
float* androsAudioOutRing(AndrOSAudioShared* p);
/// Giris halkasi (telefon -> Mac).
float* androsAudioInRing(AndrOSAudioShared* p);

#endif
