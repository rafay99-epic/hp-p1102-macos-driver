// CUPS filter: Quartz 8-bit gray raster -> 1-bit PBM -> foo2zjs -z2 (ZjStream).
// Uses no Ghostscript, so it runs inside the CUPS sandbox.

#include <cups/cups.h>
#include <cups/raster.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef FOO2ZJS
#define FOO2ZJS "/Library/Printers/HP-P1102/bin/foo2zjs"
#endif

extern char **environ;

#define CELL 8

typedef struct { const char *name; int w, h, code; } Paper;

// Page sizes in points -> P1102 (-z2) paper codes.
static const Paper papers[] = {
  {"Letter", 612, 792, 1},       {"Legal", 612, 1008, 5},
  {"Executive", 522, 756, 7},    {"A4", 595, 842, 9},
  {"A5", 420, 595, 11},          {"B5", 516, 729, 13},
  {"Env10", 297, 684, 20},       {"EnvDL", 312, 624, 27},
  {"EnvC5", 459, 649, 28},       {"EnvB5", 499, 709, 34},
  {"EnvMonarch", 279, 540, 37},  {"Postcard", 283, 420, 43},
  {"A6", 297, 420, 70},
};

typedef struct { const char *name; int code; } Media;

static const Media medias[] = {
  {"Plain", 1}, {"Transparency", 2}, {"Light", 258}, {"Heavy", 262},
  {"Rough", 263}, {"Labels", 265}, {"Envelope", 267}, {"Recycled", 516},
};

static int paper_code(const cups_page_header2_t *h) {
  for (size_t i = 0; i < sizeof papers / sizeof *papers; i++)
    if (abs((int)h->PageSize[0] - papers[i].w) <= 2 &&
        abs((int)h->PageSize[1] - papers[i].h) <= 2)
      return papers[i].code;
  fprintf(stderr, "WARNING: unknown page size %ux%u pt, sending as A4\n",
          h->PageSize[0], h->PageSize[1]);
  return 9;
}

static int media_code(const cups_page_header2_t *h) {
  for (size_t i = 0; i < sizeof medias / sizeof *medias; i++)
    if (!strcasecmp(h->MediaType, medias[i].name)) return medias[i].code;
  return 1;
}

// 75 lpi clustered-dot screen. Laser engines hold clustered dots far better
// than dispersed dither.
static unsigned char thresh[CELL][CELL];

static void build_screen(void) {
  double spot[CELL * CELL];
  int order[CELL * CELL];
  for (int i = 0; i < CELL * CELL; i++) {
    double x = ((i % CELL) + 0.5) / CELL * 2 - 1, y = ((i / CELL) + 0.5) / CELL * 2 - 1;
    spot[i] = cos(M_PI * x) + cos(M_PI * y);
    order[i] = i;
  }
  for (int i = 1; i < CELL * CELL; i++)
    for (int j = i; j > 0 && spot[order[j]] > spot[order[j - 1]]; j--) {
      int t = order[j]; order[j] = order[j - 1]; order[j - 1] = t;
    }
  for (int rank = 0; rank < CELL * CELL; rank++)
    thresh[order[rank] / CELL][order[rank] % CELL] =
        (unsigned char)((rank * 255 + 127) / (CELL * CELL));
}

// cgpdftoraster already crops to the PPD ImageableArea (96px per edge), so
// passing -u/-l here would clip the page twice.
static FILE *spawn_foo2zjs(const cups_page_header2_t *h, int density, int draft,
                           pid_t *pid) {
  char geom[32], paper[16], media[16], dens[8];
  snprintf(geom, sizeof geom, "%ux%u", h->cupsWidth, h->cupsHeight);
  snprintf(paper, sizeof paper, "%d", paper_code(h));
  snprintf(media, sizeof media, "%d", media_code(h));
  snprintf(dens, sizeof dens, "%d", density);

  char *argv[24];
  int n = 0;
  argv[n++] = "foo2zjs";
  argv[n++] = "-z2"; argv[n++] = "-P"; argv[n++] = "-L0";
  argv[n++] = "-r600x600";
  argv[n++] = "-g"; argv[n++] = geom;
  argv[n++] = "-p"; argv[n++] = paper;
  argv[n++] = "-m"; argv[n++] = media;
  argv[n++] = "-T"; argv[n++] = dens;
  if (draft) argv[n++] = "-t";
  argv[n] = NULL;

  int fds[2];
  if (pipe(fds)) return NULL;
  posix_spawn_file_actions_t fa;
  posix_spawn_file_actions_init(&fa);
  posix_spawn_file_actions_adddup2(&fa, fds[0], 0);
  posix_spawn_file_actions_addclose(&fa, fds[1]);
  int rc = posix_spawn(pid, FOO2ZJS, &fa, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&fa);
  close(fds[0]);
  if (rc) {
    fprintf(stderr, "ERROR: cannot run %s: %s\n", FOO2ZJS, strerror(rc));
    close(fds[1]);
    return NULL;
  }
  fprintf(stderr, "DEBUG: foo2zjs -g %s -p %s -m %s -T %s%s\n", geom, paper,
          media, dens, draft ? " -t" : "");
  return fdopen(fds[1], "w");
}

static void halftone_line(const cups_page_header2_t *h, const unsigned char *in,
                          unsigned char *out, unsigned y) {
  size_t bpl = (h->cupsWidth + 7) / 8;
  memset(out, 0, bpl);
  // CUPS_CSPACE_K stores ink (255 = black); W/SW store light.
  int ink = h->cupsColorSpace == CUPS_CSPACE_K;
  const unsigned char *row = thresh[y % CELL];
  for (unsigned x = 0; x < h->cupsWidth; x++) {
    unsigned char dark = ink ? in[x] : 255 - in[x];
    if (dark > row[x % CELL]) out[x >> 3] |= 0x80 >> (x & 7);
  }
}

int main(int argc, char *argv[]) {
  if (argc < 6 || argc > 7) {
    fputs("Usage: rastertozjs job user title copies options [file]\n", stderr);
    return 1;
  }
  signal(SIGPIPE, SIG_IGN);

  int fd = argc == 7 ? open(argv[6], O_RDONLY) : 0;
  if (fd < 0) {
    fprintf(stderr, "ERROR: cannot open %s: %s\n", argv[6], strerror(errno));
    return 1;
  }
  cups_raster_t *ras = cupsRasterOpen(fd, CUPS_RASTER_READ);
  build_screen();

  cups_page_header2_t h;
  FILE *zjs = NULL;
  pid_t pid = 0;
  int page = 0, failed = 0;
  unsigned char *in = NULL, *out = NULL;

  while (cupsRasterReadHeader2(ras, &h)) {
    if (h.cupsBitsPerColor != 8 || h.cupsNumColors != 1) {
      fprintf(stderr, "ERROR: expected 8-bit gray raster, got %u-bit x %u\n",
              h.cupsBitsPerColor, h.cupsNumColors);
      failed = 1;
      break;
    }
    // Set by the PPD: cupsInteger0 = Density (1-5), cupsInteger1 = TonerSave.
    int density = h.cupsInteger[0] >= 1 && h.cupsInteger[0] <= 5 ? (int)h.cupsInteger[0] : 3;
    if (!zjs && !(zjs = spawn_foo2zjs(&h, density, h.cupsInteger[1] != 0, &pid))) {
      failed = 1;
      break;
    }
    fprintf(stderr, "PAGE: %d 1\n", ++page);
    fprintf(stderr, "INFO: Printing page %d\n", page);

    in = realloc(in, h.cupsBytesPerLine);
    out = realloc(out, (h.cupsWidth + 7) / 8);
    fprintf(zjs, "P4\n%u %u\n", h.cupsWidth, h.cupsHeight);
    for (unsigned y = 0; y < h.cupsHeight; y++) {
      if (!cupsRasterReadPixels(ras, in, h.cupsBytesPerLine)) {
        memset(in, h.cupsColorSpace == CUPS_CSPACE_K ? 0 : 255, h.cupsBytesPerLine);
      }
      halftone_line(&h, in, out, y);
      fwrite(out, 1, (h.cupsWidth + 7) / 8, zjs);
    }
  }

  cupsRasterClose(ras);
  if (fd) close(fd);
  free(in);
  free(out);

  if (zjs) {
    fclose(zjs);
    int status = 0;
    waitpid(pid, &status, 0);
    if (!WIFEXITED(status) || WEXITSTATUS(status)) {
      fprintf(stderr, "ERROR: foo2zjs failed (status %d)\n", status);
      failed = 1;
    }
  }
  if (!page && !failed) fputs("ERROR: no pages found\n", stderr);
  return failed || !page;
}
