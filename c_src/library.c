#include "erl_nif.h"
#include <git2.h>

ERL_NIF_TERM git_engine_library_version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	int major, minor, rev;

	git_libgit2_version(&major, &minor, &rev);

	return enif_make_tuple3(env, enif_make_int(env, major), enif_make_int(env, minor), enif_make_int(env, rev));
}

/*
 * Process-wide, in bytes: the limits on cached object data and on mapped pack data, and the size
 * of one mapped pack window. A window in use is never unmapped, so the mapped limit alone cannot
 * shrink a mapping as big as the pack.
 */
ERL_NIF_TERM git_engine_library_set_memory_limits(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	ErlNifSInt64 cache, mapped, window;

	if (!enif_get_int64(env, argv[0], &cache) || !enif_get_int64(env, argv[1], &mapped) ||
		!enif_get_int64(env, argv[2], &window) || cache < 0 || mapped < 0 || window < 0)
		return enif_make_badarg(env);

	if (git_libgit2_opts(GIT_OPT_SET_CACHE_MAX_SIZE, (ssize_t) cache) < 0 ||
		git_libgit2_opts(GIT_OPT_SET_MWINDOW_MAPPED_LIMIT, (size_t) mapped) < 0 ||
		git_libgit2_opts(GIT_OPT_SET_MWINDOW_SIZE, (size_t) window) < 0)
		return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "eunknown"));

	return enif_make_atom(env, "ok");
}
