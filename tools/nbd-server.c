/*
 * Simple static NBD server for exposing a block device over TCP.
 * Implements the classic NBD protocol.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <linux/fs.h>

#define NBD_REQUEST_MAGIC 0x25609513
#define NBD_REPLY_MAGIC   0x67446698

#define NBD_CMD_READ  0
#define NBD_CMD_WRITE 1
#define NBD_CMD_DISC  2
#define NBD_CMD_FLUSH 3

static int read_all(int fd, void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = read(fd, (char *)buf + done, len - done);
        if (n <= 0) return -1;
        done += n;
    }
    return 0;
}

static int write_all(int fd, const void *buf, size_t len) {
    size_t done = 0;
    while (done < len) {
        ssize_t n = write(fd, (char *)buf + done, len - done);
        if (n <= 0) return -1;
        done += n;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <device> <port>\n", argv[0]);
        return 1;
    }

    const char *dev_path = argv[1];
    int port = atoi(argv[2]);

    int dev_fd = open(dev_path, O_RDWR | O_SYNC);
    if (dev_fd < 0) {
        perror("open device");
        return 1;
    }

    uint64_t size = 0;
    if (ioctl(dev_fd, BLKGETSIZE64, &size) < 0) {
        struct stat st;
        if (fstat(dev_fd, &st) < 0) {
            perror("fstat");
            return 1;
        }
        size = st.st_size;
    }

    printf("Serving %s (%llu bytes) on port %d\n", dev_path, (unsigned long long)size, port);

    int sfd = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_port = htons(port);
    sin.sin_addr.s_addr = INADDR_ANY;

    if (bind(sfd, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
        perror("bind");
        return 1;
    }
    listen(sfd, 1);

    int cfd = accept(sfd, NULL, NULL);
    if (cfd < 0) {
        perror("accept");
        return 1;
    }
    setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
    printf("Client connected\n");

    /* Classic handshake */
    /* 1. passwd: "NBDMAGIC" */
    write_all(cfd, "NBDMAGIC", 8);
    /* 2. cliserv_magic: 0x00420281861253ULL */
    uint64_t cliserv_magic = htobe64(0x00420281861253ULL);
    write_all(cfd, &cliserv_magic, 8);
    /* 3. export size */
    uint64_t be_size = htobe64(size);
    write_all(cfd, &be_size, 8);
    /* 4. flags (0) */
    uint32_t flags = 0;
    write_all(cfd, &flags, 4);
    /* 5. 124 reserved zeroes */
    char zeroes[124] = {0};
    write_all(cfd, zeroes, 124);

    /* Request loop */
    char buf[65536];
    while (1) {
        uint32_t req_magic, req_type, req_len;
        uint64_t req_handle, req_from;

        if (read_all(cfd, &req_magic, 4) < 0) break;
        req_magic = be32toh(req_magic);
        if (req_magic != NBD_REQUEST_MAGIC) {
            fprintf(stderr, "Bad request magic: 0x%08x\n", req_magic);
            break;
        }

        read_all(cfd, &req_type, 4);
        req_type = be32toh(req_type);
        read_all(cfd, &req_handle, 8);
        read_all(cfd, &req_from, 8);
        req_from = be64toh(req_from);
        read_all(cfd, &req_len, 4);
        req_len = be32toh(req_len);

        if (req_type == NBD_CMD_DISC) {
            printf("Client requested disconnect\n");
            break;
        }

        uint32_t rep_magic = htobe32(NBD_REPLY_MAGIC);
        uint32_t rep_error = 0;

        if (req_type == NBD_CMD_READ) {
            /* Reply header */
            write_all(cfd, &rep_magic, 4);
            write_all(cfd, &rep_error, 4);
            write_all(cfd, &req_handle, 8);

            /* Stream data in chunks */
            uint64_t cur = req_from;
            uint32_t rem = req_len;
            while (rem > 0) {
                size_t chunk = rem > sizeof(buf) ? sizeof(buf) : rem;
                ssize_t n = pread(dev_fd, buf, chunk, cur);
                if (n <= 0) {
                    memset(buf, 0, chunk);
                    n = chunk;
                }
                write_all(cfd, buf, n);
                cur += n;
                rem -= n;
            }
        } else if (req_type == NBD_CMD_WRITE) {
            uint64_t cur = req_from;
            uint32_t rem = req_len;
            while (rem > 0) {
                size_t chunk = rem > sizeof(buf) ? sizeof(buf) : rem;
                read_all(cfd, buf, chunk);
                pwrite(dev_fd, buf, chunk, cur);
                cur += chunk;
                rem -= chunk;
            }

            /* Reply header */
            write_all(cfd, &rep_magic, 4);
            write_all(cfd, &rep_error, 4);
            write_all(cfd, &req_handle, 8);
        } else if (req_type == NBD_CMD_FLUSH) {
            fdatasync(dev_fd);
            write_all(cfd, &rep_magic, 4);
            write_all(cfd, &rep_error, 4);
            write_all(cfd, &req_handle, 8);
        } else {
            /* Unknown command */
            rep_error = htobe32(EINVAL);
            write_all(cfd, &rep_magic, 4);
            write_all(cfd, &rep_error, 4);
            write_all(cfd, &req_handle, 8);
        }
    }

    close(cfd);
    close(sfd);
    close(dev_fd);
    printf("Server finished.\n");
    return 0;
}

