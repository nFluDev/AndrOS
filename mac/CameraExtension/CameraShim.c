#include "AndrOSCameraShim.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>

/* Uzanti ve uygulama AYNI kodu kullaniyor: kim once acarsa olusturuyor. */
AndrOSCameraShared* androsCameraAttach(int create)
{
    int fd = shm_open(ANDROS_CAM_SHM, create ? (O_CREAT | O_RDWR) : O_RDWR, 0666);
    if (fd < 0) return 0;
    if (create) {
        fchmod(fd, 0666);
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size < (off_t)sizeof(AndrOSCameraShared)) {
            if (ftruncate(fd, (off_t)sizeof(AndrOSCameraShared)) != 0) { close(fd); return 0; }
        }
    }
    void* p = mmap(0, sizeof(AndrOSCameraShared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return 0;
    AndrOSCameraShared* s = (AndrOSCameraShared*)p;
    if (s->magic != ANDROS_CAM_MAGIC) {
        if (!create) { munmap(p, sizeof(AndrOSCameraShared)); return 0; }
        memset(s, 0, sizeof(*s));
        s->magic = ANDROS_CAM_MAGIC;
        s->version = ANDROS_CAM_VERSION;
        s->width = ANDROS_CAM_MAXW;
        s->height = ANDROS_CAM_MAXH;
    }
    return s;
}

uint8_t* androsCameraSlot(AndrOSCameraShared* p, unsigned i)
{
    return p ? p->frames[i % ANDROS_CAM_SLOTS] : 0;
}
