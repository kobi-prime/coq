(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Util
open Names
open Term
open Termops
open Namegen
open Environ
open Type_errors

type unification_error =
  | OccurCheck of existential_key * constr
  | NotClean of existential * constr
  | NotSameArgSize
  | NotSameHead
  | NoCanonicalStructure
  | ConversionFailed of env * constr * constr
  | MetaOccurInBody of existential_key
  | InstanceNotSameType of existential_key * env * types * types
  | UnifUnivInconsistency

type pretype_error =
  (* Old Case *)
  | CantFindCaseType of constr
  (* Type inference unification *)
  | ActualTypeNotCoercible of unsafe_judgment * types * unification_error
  (* Tactic unification *)
  | UnifOccurCheck of existential_key * constr
  | UnsolvableImplicit of Evd.evar_info * Evar_kinds.t *
      Evd.unsolvability_explanation option
  | CannotUnify of constr * constr * unification_error option
  | CannotUnifyLocal of constr * constr * constr
  | CannotUnifyBindingType of constr * constr
  | CannotGeneralize of constr
  | NoOccurrenceFound of constr * Id.t option
  | CannotFindWellTypedAbstraction of constr * constr list * (env * type_error) option
  | WrongAbstractionType of Name.t * constr * types * types
  | AbstractionOverMeta of Name.t * Name.t
  | NonLinearUnification of Name.t * constr
  (* Pretyping *)
  | VarNotFound of Id.t
  | UnexpectedType of constr * constr
  | NotProduct of constr
  | TypingError of type_error

exception PretypeError of env * Evd.evar_map * pretype_error

let precatchable_exception = function
  | Errors.UserError _ | TypeError _ | PretypeError _
  | Nametab.GlobalizationError _ -> true
  | _ -> false

(* This simplifies the typing context of Cases clauses *)
(* hope it does not disturb other typing contexts *)
let contract env lc =
  let l = ref [] in
  let contract_context (na,c,t) env =
    match c with
      | Some c' when isRel c' ->
	  l := (substl !l c') :: !l;
	  env
      | _ ->
	  let t' = substl !l t in
	  let c' = Option.map (substl !l) c in
	  let na' = named_hd env t' na in
	  l := (mkRel 1) :: List.map (lift 1) !l;
	  push_rel (na',c',t') env in
  let env = process_rel_context contract_context env in
  (env, List.map (substl !l) lc)

let contract2 env a b = match contract env [a;b] with
  | env, [a;b] -> env,a,b | _ -> assert false

let contract3 env a b c = match contract env [a;b;c] with
  | env, [a;b;c] -> env,a,b,c | _ -> assert false

let contract4 env a b c d = match contract env [a;b;c;d] with
  | env, [a;b;c;d] -> (env,a,b,c),d | _ -> assert false

let contract4_vect env a b c d v =
  match contract env ([a;b;c;d] @ Array.to_list v) with
  | env, a::b::c::d::l -> (env,a,b,c),d,Array.of_list l
  | _ -> assert false

let contract3' env a b c = function
  | OccurCheck (evk,d) -> let x,d = contract4 env a b c d in x,OccurCheck(evk,d)
  | NotClean ((evk,args),d) ->
      let x,d,args = contract4_vect env a b c d args in x,NotClean((evk,args),d)
  | ConversionFailed (env',t1,t2) ->
      let (env',t1,t2) = contract2 env' t1 t2 in
      contract3 env a b c, ConversionFailed (env',t1,t2)
  | NotSameArgSize | NotSameHead | NoCanonicalStructure
  | MetaOccurInBody _ | InstanceNotSameType _ 
  | UnifUnivInconsistency as x -> contract3 env a b c, x

let raise_pretype_error (loc,env,sigma,te) =
  Loc.raise loc (PretypeError(env,sigma,te))

let raise_located_type_error (loc,env,sigma,te) =
  Loc.raise loc (PretypeError(env,sigma,TypingError te))


let error_actual_type_loc loc env sigma {uj_val=c;uj_type=actty} expty reason =
  let (env, c, actty, expty), reason = contract3' env c actty expty reason in
  let j = {uj_val=c;uj_type=actty} in
  raise_pretype_error
    (loc, env, sigma, ActualTypeNotCoercible (j, expty, reason))

let error_cant_apply_not_functional_loc loc env sigma rator randl =
  raise_located_type_error
    (loc, env, sigma, CantApplyNonFunctional (rator, Array.of_list randl))

let error_cant_apply_bad_type_loc loc env sigma (n,c,t) rator randl =
  raise_located_type_error
    (loc, env, sigma,
       CantApplyBadType ((n,c,t), rator, Array.of_list randl))

let error_ill_formed_branch_loc loc env sigma c i actty expty =
  raise_located_type_error
    (loc, env, sigma, IllFormedBranch (c, i, actty, expty))

let error_number_branches_loc loc env sigma cj expn =
  raise_located_type_error (loc, env, sigma, NumberBranches (cj, expn))

let error_case_not_inductive_loc loc env sigma cj =
  raise_located_type_error (loc, env, sigma, CaseNotInductive cj)

let error_ill_typed_rec_body_loc loc env sigma i na jl tys =
  raise_located_type_error
    (loc, env, sigma, IllTypedRecBody (i, na, jl, tys))

let error_not_a_type_loc loc env sigma j =
  raise_located_type_error (loc, env, sigma, NotAType j)

(*s Implicit arguments synthesis errors. It is hard to find
    a precise location. *)

let error_occur_check env sigma ev c =
  raise (PretypeError (env, sigma, UnifOccurCheck (ev,c)))

let error_unsolvable_implicit loc env sigma evi e explain =
  Loc.raise loc
    (PretypeError (env, sigma, UnsolvableImplicit (evi, e, explain)))

let error_cannot_unify_loc loc env sigma ?reason (m,n) =
  let env, m, n = contract2 env m n in
  Loc.raise loc (PretypeError (env, sigma,CannotUnify (m,n,reason)))

let error_cannot_unify env sigma ?reason (m,n) =
  let env, m, n = contract2 env m n in
  raise (PretypeError (env, sigma,CannotUnify (m,n,reason)))

let error_cannot_unify_local env sigma (m,n,sn) =
  raise (PretypeError (env, sigma,CannotUnifyLocal (m,n,sn)))

let error_cannot_coerce env sigma (m,n) =
  raise (PretypeError (env, sigma,CannotUnify (m,n,None)))

let error_cannot_find_well_typed_abstraction env sigma p l e =
  raise (PretypeError (env, sigma,CannotFindWellTypedAbstraction (p,l,e)))

let error_wrong_abstraction_type env sigma na a p l =
  raise (PretypeError (env, sigma,WrongAbstractionType (na,a,p,l)))

let error_abstraction_over_meta env sigma hdmeta metaarg =
  let m = Evd.meta_name sigma hdmeta and n = Evd.meta_name sigma metaarg in
  raise (PretypeError (env, sigma,AbstractionOverMeta (m,n)))

let error_non_linear_unification env sigma hdmeta t =
  let m = Evd.meta_name sigma hdmeta in
  raise (PretypeError (env, sigma,NonLinearUnification (m,t)))

(*s Ml Case errors *)

let error_cant_find_case_type_loc loc env sigma expr =
  raise_pretype_error (loc, env, sigma, CantFindCaseType expr)

(*s Pretyping errors *)

let error_unexpected_type_loc loc env sigma actty expty =
  let env, actty, expty = contract2 env actty expty in
  raise_pretype_error (loc, env, sigma, UnexpectedType (actty, expty))

let error_not_product_loc loc env sigma c =
  raise_pretype_error (loc, env, sigma, NotProduct c)

(*s Error in conversion from AST to glob_constr *)

let error_var_not_found_loc loc s =
  raise_pretype_error (loc, empty_env, Evd.empty, VarNotFound s)
