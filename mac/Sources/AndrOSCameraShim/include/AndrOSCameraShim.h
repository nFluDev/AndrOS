#ifndef ANDROS_CAMERA_SHIM_H
#define ANDROS_CAMERA_SHIM_H
#include "AndrOSCameraShared.h"

/// Paylasimli kare tamponunu baglar. `create` = yoksa olustur.
AndrOSCameraShared* androsCameraAttach(int create);
/// `i` numarali slotun basi.
uint8_t* androsCameraSlot(AndrOSCameraShared* p, unsigned i);

#endif
