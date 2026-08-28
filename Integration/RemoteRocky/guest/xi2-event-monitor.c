#define _POSIX_C_SOURCE 200809L

#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int selection_error_code;

static int record_x_error(Display *display, XErrorEvent *error) {
    (void)display;
    selection_error_code = error->error_code;
    return 0;
}

static bool publish_ready(const char *ready_path) {
    const size_t path_length = strlen(ready_path);
    const size_t suffix_capacity = 32;
    if (path_length == 0 || path_length > SIZE_MAX - suffix_capacity) {
        return false;
    }

    char *temporary_path = malloc(path_length + suffix_capacity);
    if (temporary_path == NULL) {
        return false;
    }
    const int written = snprintf(
        temporary_path,
        path_length + suffix_capacity,
        "%s.tmp.%ld",
        ready_path,
        (long)getpid()
    );
    if (written < 0 || (size_t)written >= path_length + suffix_capacity) {
        free(temporary_path);
        return false;
    }

    const int descriptor = open(
        temporary_path,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
        0600
    );
    if (descriptor < 0) {
        free(temporary_path);
        return false;
    }
    bool succeeded = fchmod(descriptor, 0600) == 0;
    if (close(descriptor) != 0) {
        succeeded = false;
    }
    if (succeeded && rename(temporary_path, ready_path) != 0) {
        succeeded = false;
    }
    if (!succeeded) {
        (void)unlink(temporary_path);
    }
    free(temporary_path);
    return succeeded;
}

static bool emit_event(int event_type) {
    const char *name = NULL;
    switch (event_type) {
    case XI_RawKeyPress:
        name = "RawKeyPress";
        break;
    case XI_RawButtonPress:
        name = "RawButtonPress";
        break;
    case XI_RawMotion:
        name = "RawMotion";
        break;
    default:
        return true;
    }
    if (printf("EVENT type %d (%s)\n", event_type, name) < 0) {
        return false;
    }
    return fflush(stdout) == 0 && !ferror(stdout);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: xi2-event-monitor READY_PATH\n");
        return 2;
    }
    (void)signal(SIGPIPE, SIG_IGN);
    (void)umask(0077);

    Display *display = XOpenDisplay(NULL);
    if (display == NULL) {
        fprintf(stderr, "xi2-event-monitor: XOpenDisplay failed\n");
        return 1;
    }

    int xi_opcode = 0;
    int first_event = 0;
    int first_error = 0;
    if (!XQueryExtension(
            display,
            "XInputExtension",
            &xi_opcode,
            &first_event,
            &first_error
        )) {
        fprintf(stderr, "xi2-event-monitor: XInput extension unavailable\n");
        XCloseDisplay(display);
        return 1;
    }

    int major_version = 2;
    int minor_version = 0;
    if (XIQueryVersion(display, &major_version, &minor_version) != Success
        || major_version < 2) {
        fprintf(stderr, "xi2-event-monitor: XI2 unavailable\n");
        XCloseDisplay(display);
        return 1;
    }

    unsigned char mask[XIMaskLen(XI_LASTEVENT)] = {0};
    XISetMask(mask, XI_RawKeyPress);
    XISetMask(mask, XI_RawButtonPress);
    XISetMask(mask, XI_RawMotion);
    XIEventMask event_mask = {
        .deviceid = XIAllMasterDevices,
        .mask_len = (int)sizeof(mask),
        .mask = mask,
    };

    selection_error_code = 0;
    XErrorHandler previous_error_handler = XSetErrorHandler(record_x_error);
    const int selection_status = XISelectEvents(
        display,
        DefaultRootWindow(display),
        &event_mask,
        1
    );
    const int sync_status = XSync(display, False);
    (void)XSetErrorHandler(previous_error_handler);
    if (selection_status != Success || sync_status == 0
        || selection_error_code != 0) {
        fprintf(stderr, "xi2-event-monitor: XI2 selection failed\n");
        XCloseDisplay(display);
        return 1;
    }

    if (!publish_ready(argv[1])) {
        fprintf(
            stderr,
            "xi2-event-monitor: ready publication failed: %s\n",
            strerror(errno)
        );
        XCloseDisplay(display);
        return 1;
    }

    while (true) {
        XEvent event;
        if (XNextEvent(display, &event) != 0) {
            fprintf(stderr, "xi2-event-monitor: XNextEvent failed\n");
            XCloseDisplay(display);
            return 1;
        }
        if (event.type != GenericEvent
            || event.xcookie.extension != xi_opcode
            || !XGetEventData(display, &event.xcookie)) {
            continue;
        }
        const int event_type = event.xcookie.evtype;
        const bool emitted = emit_event(event_type);
        XFreeEventData(display, &event.xcookie);
        if (!emitted) {
            fprintf(stderr, "xi2-event-monitor: stdout failed\n");
            XCloseDisplay(display);
            return 1;
        }
    }
}
