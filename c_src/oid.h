#ifndef GIT_ENGINE_OID_H
#define GIT_ENGINE_OID_H

#include "erl_nif.h"
#include <git2.h>

ERL_NIF_TERM git_engine_oid_fmt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
ERL_NIF_TERM git_engine_oid_parse(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]);
int git_engine_oid_bin(ErlNifBinary *bin, const git_oid *id);

#endif
