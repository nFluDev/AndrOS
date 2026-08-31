#include "AndrOSAudioShim.h"

#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

AndrOSAudioShared* androsAudioAttach(void)
{
    int fd = shm_open(ANDROS_SHM_NAME, O_RDWR, 0666);
    if (fd < 0) return 0;
    void* p = mmap(0, sizeof(AndrOSAudioShared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return 0;
    AndrOSAudioShared* s = (AndrOSAudioShared*)p;
    if (s->magic != ANDROS_MAGIC) { munmap(p, sizeof(AndrOSAudioShared)); return 0; }
    return s;
}

void androsAudioDetach(AndrOSAudioShared* p)
{
    if (p) munmap((void*)p, sizeof(AndrOSAudioShared));
}

float* androsAudioOutRing(AndrOSAudioShared* p) { return p ? p->out : 0; }
float* androsAudioInRing(AndrOSAudioShared* p)  { return p ? p->in  : 0; }
