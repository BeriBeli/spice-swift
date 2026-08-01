#include <X11/Xlib.h>
#include <X11/extensions/XShm.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <time.h>

static void fail(const char *message)
{
    fprintf(stderr, "swiftspice-x11-animation: %s\n", message);
    exit(EXIT_FAILURE);
}

int main(void)
{
    const unsigned int width = 32;
    const unsigned int height = 720;
    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        fail("cannot open X display");
    }
    if (!XShmQueryExtension(display)) {
        fail("MIT-SHM extension is unavailable");
    }

    const int screen = DefaultScreen(display);
    Window window = XCreateSimpleWindow(
        display,
        RootWindow(display, screen),
        0,
        0,
        width,
        height,
        0,
        BlackPixel(display, screen),
        BlackPixel(display, screen)
    );
    XMapRaised(display, window);
    XSync(display, False);

    XShmSegmentInfo shared = {0};
    XImage *image = XShmCreateImage(
        display,
        DefaultVisual(display, screen),
        (unsigned int)DefaultDepth(display, screen),
        ZPixmap,
        NULL,
        &shared,
        width,
        height
    );
    if (image == NULL || image->bits_per_pixel != 32) {
        fail("expected a 32-bit shared XImage");
    }
    const size_t byte_count = (size_t)image->bytes_per_line * image->height;
    shared.shmid = shmget(IPC_PRIVATE, byte_count, IPC_CREAT | 0600);
    if (shared.shmid < 0) {
        fail("shmget failed");
    }
    shared.shmaddr = shmat(shared.shmid, NULL, 0);
    if (shared.shmaddr == (char *)-1) {
        fail("shmat failed");
    }
    shared.readOnly = False;
    image->data = shared.shmaddr;
    if (!XShmAttach(display, &shared)) {
        fail("XShmAttach failed");
    }
    shmctl(shared.shmid, IPC_RMID, NULL);

    GC graphics = XCreateGC(display, window, 0, NULL);
    const uint32_t colors[] = {
        0x001769aa,
        0x00f28c28,
        0x00d7266d,
        0x00263238,
    };
    const struct timespec frame_delay = {.tv_sec = 0, .tv_nsec = 33333333};
    unsigned int frame = 0;
    for (;;) {
        uint32_t *pixels = (uint32_t *)image->data;
        const uint32_t color = colors[frame % 4];
        for (size_t pixel = 0; pixel < byte_count / sizeof(*pixels); pixel++) {
            pixels[pixel] = color;
        }
        XShmPutImage(
            display,
            window,
            graphics,
            image,
            0,
            0,
            0,
            0,
            width,
            height,
            False
        );
        XSync(display, False);
        nanosleep(&frame_delay, NULL);
        frame++;
    }
}
