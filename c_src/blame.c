#include <git2.h>
#include <string.h>

#include "ex_git_engine.h"
#include "oid.h"
#include "repository.h"
#include "blame.h"

ERL_NIF_TERM
git_engine_blame_file(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
	git_engine_repository *repo;
	ErlNifBinary path_bin;
	git_blame *blame;
	git_blame_options opts = GIT_BLAME_OPTIONS_INIT;
	ERL_NIF_TERM *terms;
	uint32_t i, count;
	int error;

	if (!enif_get_resource(env, argv[0], git_engine_repository_type, (void **) &repo))
		return enif_make_badarg(env);

	if (!enif_inspect_binary(env, argv[1], &path_bin))
		return enif_make_badarg(env);

	/* argv[2]: binary OID to blame from (newest commit), or nil for HEAD */
	if (enif_compare(argv[2], atoms.nil) != 0) {
		ErlNifBinary oid_bin;
		if (!enif_inspect_binary(env, argv[2], &oid_bin) || oid_bin.size != GIT_OID_RAWSZ)
			return enif_make_badarg(env);
		git_oid_fromraw(&opts.newest_commit, oid_bin.data);
	}

	if (!git_engine_terminate_binary(&path_bin))
		return git_engine_oom(env);

	error = git_blame_file(&blame, repo->repo, (char *) path_bin.data, &opts);
	enif_release_binary(&path_bin);

	if (error < 0)
		return git_engine_error(env);

	count = git_blame_get_hunk_count(blame);

	terms = enif_alloc(count * sizeof(ERL_NIF_TERM));
	if (!terms) {
		git_blame_free(blame);
		return git_engine_oom(env);
	}

	for (i = 0; i < count; i++) {
		const git_blame_hunk *hunk = git_blame_get_hunk_byindex(blame, i);
		ErlNifBinary oid_bin, name_bin, email_bin;
		const char *name, *email;
		git_time_t when;

		if (git_engine_oid_bin(&oid_bin, &hunk->final_commit_id) < 0) {
			enif_free(terms);
			git_blame_free(blame);
			return git_engine_oom(env);
		}

		name  = (hunk->final_signature && hunk->final_signature->name)  ? hunk->final_signature->name  : "";
		email = (hunk->final_signature && hunk->final_signature->email) ? hunk->final_signature->email : "";
		when  = (hunk->final_signature) ? hunk->final_signature->when.time : 0;

		if (git_engine_string_to_bin(&name_bin, name) < 0 ||
		    git_engine_string_to_bin(&email_bin, email) < 0) {
			enif_free(terms);
			git_blame_free(blame);
			return git_engine_oom(env);
		}

		terms[i] = enif_make_tuple6(env,
			enif_make_binary(env, &oid_bin),
			enif_make_uint(env, (unsigned) hunk->final_start_line_number),
			enif_make_uint(env, (unsigned) hunk->lines_in_hunk),
			enif_make_binary(env, &name_bin),
			enif_make_binary(env, &email_bin),
			enif_make_int64(env, (ErlNifSInt64) when)
		);
	}

	ERL_NIF_TERM list = enif_make_list_from_array(env, terms, count);
	enif_free(terms);
	git_blame_free(blame);

	return enif_make_tuple2(env, atoms.ok, list);
}
