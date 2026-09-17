#ifndef EX_GIT_ENGINE_H
#define EX_GIT_ENGINE_H

#include <git2.h>
#include "erl_nif.h"

ERL_NIF_TERM git_engine_error(ErlNifEnv *env);
ERL_NIF_TERM git_engine_error_struct(ErlNifEnv *env, int code);
ERL_NIF_TERM git_engine_oom(ErlNifEnv *env);

typedef struct {
	ERL_NIF_TERM ok;
	ERL_NIF_TERM error;
	ERL_NIF_TERM nil;
	ERL_NIF_TERM true;
	ERL_NIF_TERM false;
	ERL_NIF_TERM repository;
	ERL_NIF_TERM oid;
	ERL_NIF_TERM symbolic;
	ERL_NIF_TERM commit;
	ERL_NIF_TERM tree;
	ERL_NIF_TERM blob;
	ERL_NIF_TERM tag;
	ERL_NIF_TERM format_patch;
	ERL_NIF_TERM format_patch_header;
	ERL_NIF_TERM format_raw;
	ERL_NIF_TERM format_name_only;
	ERL_NIF_TERM format_name_status;
	ERL_NIF_TERM diff_opts_pathspec;
	ERL_NIF_TERM diff_opts_context_lines;
	ERL_NIF_TERM diff_opts_interhunk_lines;
	ERL_NIF_TERM undefined;
	ERL_NIF_TERM toposort;
	ERL_NIF_TERM timesort;
	ERL_NIF_TERM reversesort;
	ERL_NIF_TERM iterover;
	ERL_NIF_TERM reflog_entry;

	ERL_NIF_TERM indexer_total_objects;
	ERL_NIF_TERM indexer_indexed_objects;
	ERL_NIF_TERM indexer_received_objects;
	ERL_NIF_TERM indexer_local_objects;
	ERL_NIF_TERM indexer_total_deltas;
	ERL_NIF_TERM indexer_indexed_deltas;
	ERL_NIF_TERM indexer_received_bytes;

	ERL_NIF_TERM zlib_need_dict;
	ERL_NIF_TERM zlib_data_error;
	ERL_NIF_TERM zlib_stream_error;
	ERL_NIF_TERM sha1;
	ERL_NIF_TERM sha256;
	ERL_NIF_TERM enomem;
	ERL_NIF_TERM eunknown;
	ERL_NIF_TERM estruct;
	ERL_NIF_TERM emod;
	ERL_NIF_TERM ex;
	ERL_NIF_TERM emsg;
	ERL_NIF_TERM ecode;
} git_engine_atoms;

extern git_engine_atoms atoms;

static inline git_oid_t git_engine_infer_oid_type(size_t rawsz) {
#if defined(GIT_EXPERIMENTAL_SHA256) || LIBGIT2_VERSION_CHECK(2, 0, 0)
	return (rawsz == GIT_OID_SHA256_SIZE) ? GIT_OID_SHA256 : GIT_OID_SHA1;
#else
	(void)rawsz;
	return GIT_OID_SHA1;
#endif
}

static inline size_t git_engine_oid_rawsz(git_oid_t t) {
#if defined(GIT_EXPERIMENTAL_SHA256) || LIBGIT2_VERSION_CHECK(2, 0, 0)
	return (t == GIT_OID_SHA256) ? GIT_OID_SHA256_SIZE : GIT_OID_SHA1_SIZE;
#else
	(void)t;
	return GIT_OID_SHA1_SIZE;
#endif
}

static inline size_t git_engine_oid_hexsz(git_oid_t t) {
#if defined(GIT_EXPERIMENTAL_SHA256) || LIBGIT2_VERSION_CHECK(2, 0, 0)
	return (t == GIT_OID_SHA256) ? GIT_OID_SHA256_HEXSIZE : GIT_OID_SHA1_HEXSIZE;
#else
	(void)t;
	return GIT_OID_SHA1_HEXSIZE;
#endif
}

#if defined(GIT_EXPERIMENTAL_SHA256) || LIBGIT2_VERSION_CHECK(2, 0, 0)
#  define GIT_ENGINE_OID_FROMRAW(oid, data, sz) \
	git_oid_fromraw((oid), (data), git_engine_infer_oid_type(sz))
#  define GIT_ENGINE_OID_FROMSTRN(oid, str, len) \
	git_oid_fromstrn((oid), (str), (len), git_engine_infer_oid_type((len)/2))
#else
#  define GIT_ENGINE_OID_FROMRAW(oid, data, sz) git_oid_fromraw((oid), (data))
#  define GIT_ENGINE_OID_FROMSTRN(oid, str, len) git_oid_fromstrn((oid), (str), (len))
#endif

git_strarray git_strarray_from_list(ErlNifEnv *env, ERL_NIF_TERM list);

/** NUL-terminate a binary */
int git_engine_terminate_binary(ErlNifBinary *bin);
/** Copy a string into a binary */
int git_engine_string_to_bin(ErlNifBinary *bin, const char *str);

#endif
