/* fakepwd.c  -  synthetic passwd database for cages with no /etc/passwd.
 *
 * LD_PRELOAD into any dynamically linked program (ssh, ssh-keygen, curl's
 * tools, ...) that calls getpwnam/getpwuid and aborts on failure.
 *
 * User database source, in order:
 *   1. $SANDHOME_PASSWD file (standard passwd(5) format, one user per line)
 *   2. $SANDSSH_PASSWD, the name this shim answered to before it moved here.
 *      Still read, so a machine configured against the old name keeps working
 *      after an upgrade; sandhome itself sets only the first.
 *   3. /etc/sandhome/passwd
 *   4. built-in default: root with uid/gid 0, home /root, shell /bin/sh
 *
 * Build: gcc -shared -fPIC -O2 -o fakepwd.so fakepwd.c
 * Use:   LD_PRELOAD=./fakepwd.so ssh user@host
 *
 * # STOP: A PROGRAM THAT CRASHES INSTEAD OF ANSWING IS WORSE THAN A MISSING
 * DATABASE. getpwnam returning NULL is a permission-denied the operator can
 * read; a SIGSEGV is a core dump they have to hand a debugger. Both faults
 * below were measured against this file before it was fixed, and both are
 * reachable from ordinary input rather than from a caller asking for them.
 *
 *   1. THE LOOP CONDITION WROTE PAST THE ARRAY. It read
 *      `while (fgets(lines[nusers], LNLEN, f) && nusers < MAXU)`, which
 *      EVALUATES fgets FIRST: with 33+ lines it wrote lines[32], one char[1024]
 *      past the end of the array, overlapping users[0], and kept going. A
 *      40-entry file crashed the interposed program with SIGSEGV. The bound is
 *      tested first now, and the file is no longer silently truncated at it.
 *   2. strtok TREATED A RUN OF ':' AS ONE DELIMITER, so any passwd(5) line
 *      with an empty field produced fewer than seven tokens and was DROPPED.
 *      An empty password field and an empty gecos field are both ordinary:
 *        alice::1000:1000:Alice:/home/alice:/bin/sh   -> (none)
 *        bob:x:1001:1001::/home/bob:/bin/bash         -> (none)
 *        carol:x:1002:1002:Carol:/home/carol:/bin/zsh -> carol
 *      Two of three real lines vanished, and the failure mode reads as
 *      "Permission denied (publickey)" to an ssh client. Fields are now walked
 *      with strcspn/memmove, which keeps an empty field empty.
 *
 * A passwd file the caller NAMED and this shim cannot open is reported on
 * stderr rather than answered with a smaller database: a shim that silently
 * serves one account because the path was mistyped is the exact failure
 * SANDHOME_PASSWD_USERS exists to remove.
 */
#define _GNU_SOURCE
#include <pwd.h>
#include <shadow.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/types.h>

/* # NOTE: 256, NOT 32, AND THE COUNT IS REPORTED. A cage running a build as
 * several service accounts passes every name in SANDHOME_PASSWD_USERS to
 * sh_shim_write_passwd, and a 33rd one used to be the one that killed the
 * process. The limit still exists - it is a fixed table with no allocator - so
 * it is a stated one: FAKEPWD_MAX is printed to stderr when a file has more
 * entries than fit, instead of the tail of the file being dropped in silence.
 */
#define FAKEPWD_MAX 256
#define LNLEN 1024
static struct passwd users[FAKEPWD_MAX];
static char lines[FAKEPWD_MAX][LNLEN];      /* field pointers refer into these */
static struct spwd shadow_root;
static int nusers = -1;

/* split7 -> 1 when LINE carried seven colon-separated fields, empty ones
 * included. Fills FIELDS with pointers into LN. A line with more than seven
 * fields is accepted: passwd(5) has seven, and a trailing field nobody reads is
 * a smaller problem than a real account being refused. */
static int split7(char *ln, char *fields[7]) {
    int k = 0;
    char *p = ln;
    while (k < 7) {
        char *colon = strchr(p, ':');
        fields[k++] = p;
        if (!colon) break;
        *colon = 0;
        p = colon + 1;
    }
    /* The seventh field is the last one only if a colon followed the sixth. */
    return k == 7;
}

static void load(void) {
    if (nusers >= 0) return;
    nusers = 0;
    const char *path = getenv("SANDHOME_PASSWD");
    int named = 0;
    if (path) named = 1;
    if (!path) { path = getenv("SANDSSH_PASSWD"); if (path) named = 1; }
    if (!path) { path = "/etc/sandhome/passwd"; }
    FILE *f = fopen(path, "r");
    if (f) {
        int overflow = 0;
        /* The bound is tested BEFORE fgets is reached. The old condition was
         * `fgets(...) && nusers < MAXU`, which wrote lines[MAXU] first. */
        while (nusers < FAKEPWD_MAX && fgets(lines[nusers], LNLEN, f)) {
            char *ln = lines[nusers];
            char *nl = strchr(ln, '\n'); if (nl) *nl = 0;
            if (*ln == 0) continue;                 /* blank line */
            if (*ln == '#') continue;                /* comment */
            char *fields[7];
            if (!split7(ln, fields)) continue;       /* malformed: skip */
            struct passwd *u = &users[nusers++];
            u->pw_name = fields[0]; u->pw_passwd = fields[1];
            u->pw_uid = (uid_t)atoi(fields[2]); u->pw_gid = (gid_t)atoi(fields[3]);
            u->pw_gecos = fields[4]; u->pw_dir = fields[5]; u->pw_shell = fields[6];
        }
        /* Anything past the bound is counted, not dropped in silence. */
        if (nusers >= FAKEPWD_MAX) {
            char c;
            while (fread(&c, 1, 1, f) == 1)
                if (c == '\n') overflow++;
            if (overflow > 0)
                fprintf(stderr, "fakepwd: %s has more than %d entries; the last %d were not served\n",
                        path, FAKEPWD_MAX, overflow);
        }
        fclose(f);
    } else if (named) {
        /* The caller pointed at a file and it could not be read. Answering
         * with the built-in root alone would look like a working database
         * with one account in it, which is how a typo in SANDHOME_PASSWD
         * turns into "Permission denied (publickey)". */
        fprintf(stderr, "fakepwd: cannot read the passwd file named by SANDHOME_PASSWD: %s\n", path);
    }
    if (nusers == 0) {
        users[0].pw_name = "root"; users[0].pw_passwd = "x";
        users[0].pw_uid = 0; users[0].pw_gid = 0;
        users[0].pw_gecos = "root"; users[0].pw_dir = "/root";
        /* # STOP: /bin/sh, NOT /bin/bash. The built-in default named a shell
         * that this image may not carry: the rest of the tree derives the real
         * shell from ${SHELL:-/bin/sh}, and getusershell() and an sshd $SHELL
         * read this field. A default that points at a program which is not
         * there breaks a login for a reason that looks nothing like a missing
         * binary. */
        users[0].pw_shell = "/bin/sh";
        nusers = 1;
    }
    memset(&shadow_root, 0, sizeof(shadow_root));
    shadow_root.sp_namp = users[0].pw_name;
    shadow_root.sp_pwdp = "*";          /* no valid password: pubkey only */
    shadow_root.sp_lstchg = -1; shadow_root.sp_min = -1; shadow_root.sp_max = -1;
    shadow_root.sp_warn = -1; shadow_root.sp_inact = -1; shadow_root.sp_expire = -1;
}

static struct passwd *find_by_name(const char *n) {
    load();
    for (int i = 0; i < nusers; i++)
        if (strcmp(users[i].pw_name, n) == 0) return &users[i];
    return NULL;
}
static struct passwd *find_by_uid(uid_t uid) {
    load();
    for (int i = 0; i < nusers; i++)
        if (users[i].pw_uid == uid) return &users[i];
    return NULL;
}

struct passwd *getpwuid(uid_t uid) { return find_by_uid(uid); }
/* # NOTE: THERE IS NO NULL CHECK ON `n` IN getpwnam, AND THAT IS NOT AN
 * OMISSION. glibc declares the parameter __nonnull, so a `n == NULL` test is
 * dead code the compiler is right to warn about under -Wextra. Callers honour
 * the declaration; the empty-string test below is the one that is reachable
 * and is kept. */
struct passwd *getpwnam(const char *n) { return *n ? find_by_name(n) : NULL; }

/* # NOTE: THE REENTRANT FORMS IGNORE buf AND len, AND THAT IS CORRECT HERE.
 * Every string they hand back points into this file's own static tables, so
 * copying into a caller buffer would be copying from a table that is already
 * the storage. The parameters are cast to void so -Wextra stays clean, because
 * a build that emits warnings is a build whose warnings stop being read. */
int getpwuid_r(uid_t uid, struct passwd *pw, char *buf, size_t len, struct passwd **res) {
    (void)buf; (void)len;
    struct passwd *m = find_by_uid(uid);
    if (!m) { *res = NULL; return 0; }
    *pw = *m; *res = pw; return 0;
}
int getpwnam_r(const char *n, struct passwd *pw, char *buf, size_t len, struct passwd **res) {
    (void)buf; (void)len;
    struct passwd *m = *n ? find_by_name(n) : NULL;
    if (!m) { *res = NULL; return 0; }
    *pw = *m; *res = pw; return 0;
}
struct spwd *getspnam(const char *n) {
    load();
    return (n && *n && strcmp(n, users[0].pw_name) == 0) ? &shadow_root : NULL;
}
int getspnam_r(const char *n, struct spwd *sp, char *buf, size_t len, struct spwd **res) {
    (void)buf; (void)len;
    struct spwd *m = getspnam(n);
    if (!m) { *res = NULL; return 0; }
    *sp = *m; *res = sp; return 0;
}
void setpwent(void) {}
void endpwent(void) {}
struct passwd *getpwent(void) { return NULL; }
