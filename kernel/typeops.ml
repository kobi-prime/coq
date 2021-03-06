(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Errors
open Util
open Names
open Univ
open Term
open Declarations
open Environ
open Entries
open Reduction
open Inductive
open Type_errors

let conv_leq l2r = default_conv CUMUL ~l2r

let conv_leq_vecti env v1 v2 =
  Array.fold_left2_i
    (fun i c t1 t2 ->
      let c' =
        try default_conv CUMUL env t1 t2
        with NotConvertible -> raise (NotConvertibleVect i) in
      Constraint.union c c')
    Constraint.empty
    v1
    v2

let univ_check_constraints (ctx,univ) (x, cst) =
  (* TODO: simply check inclusion of cst in ctx *)
  let univ' = merge_constraints cst univ in
    x, (ctx, univ')

(* This should be a type (a priori without intension to be an assumption) *)
let type_judgment env j =
  match kind_of_term(whd_betadeltaiota env j.uj_type) with
    | Sort s -> {utj_val = j.uj_val; utj_type = s }
    | _ -> error_not_type env j

(* This should be a type intended to be assumed. The error message is *)
(* not as useful as for [type_judgment]. *)
let assumption_of_judgment env j =
  try (type_judgment env j).utj_val
  with TypeError _ ->
    error_assumption env j

(************************************************)
(* Incremental typing rules: builds a typing judgement given the *)
(* judgements for the subterms. *)

(*s Type of sorts *)

(* Prop and Set *)

let judge_of_prop =
  { uj_val = mkProp;
    uj_type = mkSort type1_sort }

let judge_of_set =
  { uj_val = mkSet;
    uj_type = mkSort type1_sort }

let judge_of_prop_contents = function
  | Null -> judge_of_prop
  | Pos -> judge_of_set

(* Type of Type(i). *)

let judge_of_type u =
  let uu = Universe.super u in
  let ctx = ContextSet.of_set (Universe.levels u) in
    ({ uj_val = mkType u;
       uj_type = mkType uu }, ctx)

(*s Type of a de Bruijn index. *)

let judge_of_relative env n =
  try
    let (_,_,typ) = lookup_rel n env in
    { uj_val  = mkRel n;
      uj_type = lift n typ }
  with Not_found ->
    error_unbound_rel env n

(* Type of variables *)
let judge_of_variable env id =
  try
    let ty = named_type id env in
    make_judge (mkVar id) ty
  with Not_found ->
    error_unbound_var env id

(* Management of context of variables. *)

(* Checks if a context of variables can be instantiated by the
   variables of the current env *)
(* TODO: check order? *)
let check_hyps_inclusion env c sign =
  Sign.fold_named_context
    (fun (id,_,ty1) () ->
      try
        let ty2 = named_type id env in
        if not (eq_constr ty2 ty1) then raise Exit
      with Not_found | Exit ->
        error_reference_variables env id c)
    sign
    ~init:()

(* Instantiation of terms on real arguments. *)

(* Make a type polymorphic if an arity *)

(* Type of constants *)

let type_of_constant env cst = constant_type env cst
let type_of_constant_in env cst = constant_type_in env cst
let type_of_constant_knowing_parameters env t _ = t

let judge_of_constant env (kn,u as cst) =
  let ctx = ContextSet.of_instance u in
  let c = mkConstU cst in
  let cb = lookup_constant kn env in
  let _ = check_hyps_inclusion env c cb.const_hyps in
  let ty, cu = type_of_constant env cst in
    (make_judge c ty, ContextSet.add_constraints ctx cu)

(* Type of a lambda-abstraction. *)

(* [judge_of_abstraction env name var j] implements the rule

 env, name:typ |- j.uj_val:j.uj_type     env, |- (name:typ)j.uj_type : s
 -----------------------------------------------------------------------
          env |- [name:typ]j.uj_val : (name:typ)j.uj_type

  Since all products are defined in the Calculus of Inductive Constructions
  and no upper constraint exists on the sort $s$, we don't need to compute $s$
*)

let judge_of_abstraction env name var j =
  { uj_val = mkLambda (name, var.utj_val, j.uj_val);
    uj_type = mkProd (name, var.utj_val, j.uj_type) }

(* Type of let-in. *)

let judge_of_letin env name defj typj j =
  { uj_val = mkLetIn (name, defj.uj_val, typj.utj_val, j.uj_val) ;
    uj_type = subst1 defj.uj_val j.uj_type }

(* Type of an application. *)

let judge_of_apply env funj argjv =
  let rec apply_rec n typ cst = function
    | [] ->
	{ uj_val  = mkApp (j_val funj, Array.map j_val argjv);
          uj_type = typ },
	cst
    | hj::restjl ->
        (match kind_of_term (whd_betadeltaiota env typ) with
          | Prod (_,c1,c2) ->
	      (try
		let c = conv_leq false env hj.uj_type c1 in
		let ctx' = Constraint.union cst c in
		apply_rec (n+1) (subst1 hj.uj_val c2) ctx' restjl
	      with NotConvertible ->
		error_cant_apply_bad_type env
		  (n,c1, hj.uj_type)
		  funj argjv)

          | _ ->
	      error_cant_apply_not_functional env funj argjv)
  in
  apply_rec 1
    funj.uj_type
    Constraint.empty
    (Array.to_list argjv)

(* Type of product *)

let sort_of_product env domsort rangsort =
  match (domsort, rangsort) with
    (* Product rule (s,Prop,Prop) *)
    | (_,       Prop Null)  -> rangsort
    (* Product rule (Prop/Set,Set,Set) *)
    | (Prop _,  Prop Pos) -> rangsort
    (* Product rule (Type,Set,?) *)
    | (Type u1, Prop Pos) ->
        begin match engagement env with
        | Some ImpredicativeSet ->
          (* Rule is (Type,Set,Set) in the Set-impredicative calculus *)
          rangsort
        | _ ->
          (* Rule is (Type_i,Set,Type_i) in the Set-predicative calculus *)
          Type (Universe.sup Universe.type0 u1)
        end
    (* Product rule (Prop,Type_i,Type_i) *)
    | (Prop Pos,  Type u2)  -> Type (Universe.sup Universe.type0 u2)
    (* Product rule (Prop,Type_i,Type_i) *)
    | (Prop Null, Type _)  -> rangsort
    (* Product rule (Type_i,Type_i,Type_i) *)
    | (Type u1, Type u2) -> Type (Universe.sup u1 u2)

(* [judge_of_product env name (typ1,s1) (typ2,s2)] implements the rule

    env |- typ1:s1       env, name:typ1 |- typ2 : s2
    -------------------------------------------------------------------------
         s' >= (s1,s2), env |- (name:typ)j.uj_val : s'

  where j.uj_type is convertible to a sort s2
*)
let judge_of_product env name t1 t2 =
  let s = sort_of_product env t1.utj_type t2.utj_type in
  { uj_val = mkProd (name, t1.utj_val, t2.utj_val);
    uj_type = mkSort s }

(* Type of a type cast *)

(* [judge_of_cast env (c,typ1) (typ2,s)] implements the rule

    env |- c:typ1    env |- typ2:s    env |- typ1 <= typ2
    ---------------------------------------------------------------------
         env |- c:typ2
*)

let judge_of_cast env cj k tj =
  let expected_type = tj.utj_val in
  try
    let c, cst =
      match k with
      | VMcast ->
          mkCast (cj.uj_val, k, expected_type),
          vm_conv CUMUL env cj.uj_type expected_type
      | DEFAULTcast ->
          mkCast (cj.uj_val, k, expected_type),
          conv_leq false env cj.uj_type expected_type
      | REVERTcast ->
          cj.uj_val,
          conv_leq true env cj.uj_type expected_type
      | NATIVEcast ->
          mkCast (cj.uj_val, k, expected_type),
          native_conv CUMUL env cj.uj_type expected_type
    in
    { uj_val = c;
      uj_type = expected_type },
      cst
  with NotConvertible ->
    error_actual_type env cj expected_type

(* Inductive types. *)

(* The type is parametric over the uniform parameters whose conclusion
   is in Type; to enforce the internal constraints between the
   parameters and the instances of Type occurring in the type of the
   constructors, we use the level variables _statically_ assigned to
   the conclusions of the parameters as mediators: e.g. if a parameter
   has conclusion Type(alpha), static constraints of the form alpha<=v
   exist between alpha and the Type's occurring in the constructor
   types; when the parameters is finally instantiated by a term of
   conclusion Type(u), then the constraints u<=alpha is computed in
   the App case of execute; from this constraints, the expected
   dynamic constraints of the form u<=v are enforced *)

(* let judge_of_inductive_knowing_parameters env ind jl = *)
(*   let c = mkInd ind in *)
(*   let (mib,mip) = lookup_mind_specif env ind in *)
(*   check_args env c mib.mind_hyps; *)
(*   let paramstyp = Array.map (fun j -> j.uj_type) jl in *)
(*   let t =  in *)
(*   make_judge c t *)

let judge_of_inductive env (ind,u as indu) =
  let c = mkIndU indu in
  let (mib,mip) = lookup_mind_specif env ind in
  check_hyps_inclusion env c mib.mind_hyps;
  let ctx = ContextSet.of_instance u in
  let t,cst = Inductive.constrained_type_of_inductive env ((mib,mip),u) in
    (make_judge c t, ContextSet.add_constraints ctx cst)

(* Constructors. *)

let judge_of_constructor env (c,u as cu) =
  let constr = mkConstructU cu in
  let _ =
    let ((kn,_),_) = c in
    let mib = lookup_mind kn env in
    check_hyps_inclusion env constr mib.mind_hyps in
  let specif = lookup_mind_specif env (inductive_of_constructor c) in
  let ctx = ContextSet.of_instance u in
  let t,cst = constrained_type_of_constructor cu specif in
    (make_judge constr t, ContextSet.add_constraints ctx cst)

(* Case. *)

let check_branch_types env (ind,u) cj (lfj,explft) =
  try conv_leq_vecti env (Array.map j_type lfj) explft
  with
      NotConvertibleVect i ->
        error_ill_formed_branch env cj.uj_val ((ind,i+1),u) lfj.(i).uj_type explft.(i)
    | Invalid_argument _ ->
        error_number_branches env cj (Array.length explft)

let judge_of_case env ci pj cj lfj =
  let (pind, _ as indspec) =
    try find_rectype env cj.uj_type
    with Not_found -> error_case_not_inductive env cj in
  let _ = check_case_info env pind ci in
  let (bty,rslty,univ) =
    type_case_branches env indspec pj cj.uj_val in
  let univ' = check_branch_types env pind cj (lfj,bty) in
  ({ uj_val  = mkCase (ci, (*nf_betaiota*) pj.uj_val, cj.uj_val,
                       Array.map j_val lfj);
     uj_type = rslty },
   (Constraint.union univ univ'))

(* Fixpoints. *)

(* Checks the type of a general (co)fixpoint, i.e. without checking *)
(* the specific guard condition. *)

let type_fixpoint env lna lar vdefj =
  let lt = Array.length vdefj in
  assert (Int.equal (Array.length lar) lt);
  try
    conv_leq_vecti env (Array.map j_type vdefj) (Array.map (fun ty -> lift lt ty) lar)
  with NotConvertibleVect i ->
    error_ill_typed_rec_body env i lna vdefj lar

(************************************************************************)
(************************************************************************)

open Pp

(* This combinator adds the universe constraints both in the local
   graph and in the universes of the environment. This is to ensure
   that the infered local graph is satisfiable. *)
let univ_combinator (ctx,univ) (j,ctx') =
  (j,(ContextSet.union ctx ctx', merge_constraints (ContextSet.constraints ctx') univ))

let univ_combinator_cst (ctx,univ) (j,cst) =
  (j,(ContextSet.add_constraints ctx cst, merge_constraints cst univ))

(* The typing machine. *)
    (* ATTENTION : faudra faire le typage du contexte des Const,
    Ind et Constructsi un jour cela devient des constructions
    arbitraires et non plus des variables *)
let rec execute env cstr cu =
  match kind_of_term cstr with
    (* Atomic terms *)
    | Sort (Prop c) ->
	(judge_of_prop_contents c, cu)

    | Sort (Type u) ->
       univ_combinator cu (judge_of_type u)

    | Rel n ->
	(judge_of_relative env n, cu)

    | Var id ->
	(judge_of_variable env id, cu)

    | Const c ->
        univ_combinator cu (judge_of_constant env c)

    (* Lambda calculus operators *)
    | App (f,args) ->
        let (jl,cu1) = execute_array env args cu in
	let (j,cu2) =
	  (* match kind_of_term f with *)
	  (*   | Ind ind -> *)
	  (* 	(\* Sort-polymorphism of inductive types *\) *)
	  (* 	judge_of_inductive_knowing_parameters env ind jl, cu1 *)
	  (*   | Const cst -> *)
	  (* 	(\* Sort-polymorphism of constant *\) *)
	  (* 	judge_of_constant_knowing_parameters env cst jl, cu1 *)
	  (*   | _ -> *)
	  (* 	(\* No sort-polymorphism *\) *)
		execute env f cu1
	in
	univ_combinator_cst cu2 (judge_of_apply env j jl)

    | Lambda (name,c1,c2) ->
        let (varj,cu1) = execute_type env c1 cu in
	let env1 = push_rel (name,None,varj.utj_val) env in
        let (j',cu2) = execute env1 c2 cu1 in
        (judge_of_abstraction env name varj j', cu2)

    | Prod (name,c1,c2) ->
        let (varj,cu1) = execute_type env c1 cu in
	let env1 = push_rel (name,None,varj.utj_val) env in
        let (varj',cu2) = execute_type env1 c2 cu1 in
	(judge_of_product env name varj varj', cu2)

    | LetIn (name,c1,c2,c3) ->
        let (j1,cu1) = execute env c1 cu in
        let (j2,cu2) = execute_type env c2 cu1 in
        let (_,cu3) =
	  univ_check_constraints cu2 (judge_of_cast env j1 DEFAULTcast j2) in
        let env1 = push_rel (name,Some j1.uj_val,j2.utj_val) env in
        let (j',cu4) = execute env1 c3 cu3 in
        (judge_of_letin env name j1 j2 j', cu4)

    | Cast (c,k, t) ->
        let (cj,cu1) = execute env c cu in
        let (tj,cu2) = execute_type env t cu1 in
	univ_combinator_cst cu2
          (judge_of_cast env cj k tj)

    (* Inductive types *)
    | Ind ind ->
       univ_combinator cu (judge_of_inductive env ind)

    | Construct c ->
       univ_combinator cu (judge_of_constructor env c)

    | Case (ci,p,c,lf) ->
        let (cj,cu1) = execute env c cu in
        let (pj,cu2) = execute env p cu1 in
        let (lfj,cu3) = execute_array env lf cu2 in
        univ_combinator_cst cu3
          (judge_of_case env ci pj cj lfj)

    | Fix ((vn,i as vni),recdef) ->
        let ((fix_ty,recdef'),cu1) = execute_recdef env recdef i cu in
        let fix = (vni,recdef') in
        check_fix env fix;
	(make_judge (mkFix fix) fix_ty, cu1)

    | CoFix (i,recdef) ->
        let ((fix_ty,recdef'),cu1) = execute_recdef env recdef i cu in
        let cofix = (i,recdef') in
        check_cofix env cofix;
	(make_judge (mkCoFix cofix) fix_ty, cu1)

    (* Partial proofs: unsupported by the kernel *)
    | Meta _ ->
	anomaly (Pp.str "the kernel does not support metavariables")

    | Evar _ ->
	anomaly (Pp.str "the kernel does not support existential variables")

and execute_type env constr cu =
  let (j,cu1) = execute env constr cu in
  (type_judgment env j, cu1)

and execute_recdef env (names,lar,vdef) i cu =
  let (larj,cu1) = execute_array env lar cu in
  let lara = Array.map (assumption_of_judgment env) larj in
  let env1 = push_rec_types (names,lara,vdef) env in
  let (vdefj,cu2) = execute_array env1 vdef cu1 in
  let vdefv = Array.map j_val vdefj in
  let cst = type_fixpoint env1 names lara vdefj in
  univ_combinator_cst cu2
    ((lara.(i),(names,lara,vdefv)), cst)

and execute_array env = Array.fold_map' (execute env)

(* Derived functions *)
let infer env constr =
  let univs = (ContextSet.empty, universes env) in
  let (j,(cst,_)) = execute env constr univs in
    assert (eq_constr j.uj_val constr);
    j, cst

let infer_type env constr =
  let univs = (ContextSet.empty, universes env) in
  let (j,(cst,_)) = execute_type env constr univs in
    j, cst

let infer_v env cv =
  let univs = (ContextSet.empty, universes env) in
  let (jv,(cst,_)) = execute_array env cv univs in
    jv, cst

(* Typing of several terms. *)

let infer_local_decl env id = function
  | LocalDef c ->
      let j, cst = infer env c in
      (Name id, Some j.uj_val, j.uj_type), cst
  | LocalAssum c ->
      let j, cst = infer env c in
      (Name id, None, assumption_of_judgment env j), cst

let infer_local_decls env decls =
  let rec inferec env = function
  | (id, d) :: l ->
      let (env, l), ctx = inferec env l in
      let d, ctx' = infer_local_decl env id d in
	(push_rel d env, add_rel_decl d l), ContextSet.union ctx' ctx
  | [] -> (env, empty_rel_context), ContextSet.empty in
  inferec env decls

(* Exported typing functions *)

let typing env c =
  let j, cst = infer env c in
    j, cst
