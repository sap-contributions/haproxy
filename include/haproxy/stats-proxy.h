#ifndef _HAPROXY_STATS_PROXY_H
#define _HAPROXY_STATS_PROXY_H

#include <haproxy/api-t.h>

struct buffer;
struct htx;
struct stconn;
struct server;

int stats_dump_proxies(struct stconn *sc, struct buffer *buf, struct htx *htx);

void proxy_stats_clear_counters(int clrall, struct list *stat_modules);
void srv_stats_clear_extra_counters(struct server *sv);

#endif /* _HAPROXY_STATS_PROXY_H */
