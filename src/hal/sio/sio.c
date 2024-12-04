/* SPDX-License-Identifier: MIT
 * 
 * Author: Jérémie Faucher-Goulet
 *
 * Communicate with Super I/O chip F71869A on QNAP TVS-663 
 */

#include <stdio.h>
#include <errno.h>
#include <sys/io.h>

#define BASEPORT 0xa05
#define NPORTS 2

#define COPY_BUTTON   0xe2
#define COPY_BUTTON_B (1 << 2)

int main() {
  if (ioperm(BASEPORT, NPORTS, 1)) { perror("ioperm"); return(1); }

  // Poll USB COPY button
  outb(COPY_BUTTON, BASEPORT);
  while (1) {
    int value = inb(BASEPORT + 1) & COPY_BUTTON_B;
    printf("COPY button: %s\n", value ? "released" : "pressed");
    usleep(1000000);
  }
  if (ioperm(BASEPORT, NPORTS, 0)) { perror("ioperm"); return(1); }
}