#include <stdio.h>
#include <xcb/xcb.h>

int main(void) {
    xcb_connection_t *connection = xcb_connect(NULL, NULL);
    const int error = xcb_connection_has_error(connection);
    xcb_disconnect(connection);
    if (error != 0) {
        fprintf(stderr, "XCB display authentication/connection failed (xcb error %d)\n", error);
        return 2;
    }
    puts("guest_xcb_display_auth=PASS");
    return 0;
}
