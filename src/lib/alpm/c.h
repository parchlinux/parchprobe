#include <alpm.h>
#include <alpm_list.h>

#ifndef ROOTDIR
#define ROOTDIR "/"
#endif
#ifndef DBPATH
#define DBPATH "/var/lib/pacman/"
#endif
#ifndef LOGFILE
#define LOGFILE "/var/log/pacman.log"
#endif
#ifndef CACHEDIR
#define CACHEDIR "/var/cache/pacman/pkg/"
#endif
#ifndef HOOKDIR
#define HOOKDIR "/etc/pacman.d/hooks/"
#endif
#ifndef GPGDIR
#define GPGDIR "/etc/pacman.d/gnupg/"
#endif
