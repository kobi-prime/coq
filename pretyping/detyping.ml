(***********************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team    *)
(* <O___,, *        INRIA-Rocquencourt  &  LRI-CNRS-Orsay              *)
(*   \VV/  *************************************************************)
(*    //   *      This file is distributed under the terms of the      *)
(*         *       GNU Lesser General Public License Version 2.1       *)
(***********************************************************************)

(* $Id$ *)

open Pp
open Util
open Univ
open Names
open Term
open Declarations
open Inductive
open Inductiveops
open Environ
open Sign
open Declare
open Rawterm
open Nameops
open Termops
open Libnames
open Nametab

(****************************************************************************)
(* Tools for printing of Cases                                              *)

let encode_inductive qid =
  let indsp = global_inductive qid in
  let constr_lengths = mis_constr_nargs indsp in
  (indsp,constr_lengths)

(* Parameterization of the translation from constr to ast      *)

(* Tables for Cases printing under a "if" form, a "let" form,  *)

let isomorphic_to_bool lc =
  Array.length lc = 2 & lc.(0) = 0 & lc.(1) = 0

let isomorphic_to_tuple lc = (Array.length lc = 1)

let encode_bool r =
  let (_,lc as x) = encode_inductive r in
  if not (isomorphic_to_bool lc) then
    user_err_loc (loc_of_reference r,"encode_if",
      str "This type cannot be seen as a boolean type");
  x

let encode_tuple r =
  let (_,lc as x) = encode_inductive r in
  if not (isomorphic_to_tuple lc) then
    user_err_loc (loc_of_reference r,"encode_tuple",
      str "This type cannot be seen as a tuple type");
  x

module PrintingCasesMake =
  functor (Test : sig 
     val encode : reference -> inductive * int array
     val member_message : std_ppcmds -> bool -> std_ppcmds
     val field : string
     val title : string
  end) ->
  struct
    type t = inductive * int array
    let encode = Test.encode
    let subst subst ((kn,i), ints as obj) =
      let kn' = subst_kn subst kn in
	if kn' == kn then obj else
	  (kn',i), ints
    let printer (ind,_) = pr_global_env None (IndRef ind)
    let key = Goptions.SecondaryTable ("Printing",Test.field)
    let title = Test.title
    let member_message x = Test.member_message (printer x)
    let synchronous = true
  end

module PrintingCasesIf =
  PrintingCasesMake (struct 
    let encode = encode_bool
    let field = "If"
    let title = "Types leading to pretty-printing of Cases using a `if' form: "
    let member_message s b =
      str "Cases on elements of " ++ s ++ 
      str
	(if b then " are printed using a `if' form"
         else " are not printed using a `if' form")
  end)

module PrintingCasesLet =
  PrintingCasesMake (struct 
    let encode = encode_tuple
    let field = "Let"
    let title = 
      "Types leading to a pretty-printing of Cases using a `let' form:"
    let member_message s b =
      str "Cases on elements of " ++ s ++
      str
	(if b then " are printed using a `let' form"
         else " are not printed using a `let' form")
  end)

module PrintingIf  = Goptions.MakeRefTable(PrintingCasesIf)
module PrintingLet = Goptions.MakeRefTable(PrintingCasesLet)

let force_let ci =
  let indsp = ci.ci_ind in
  let lc = mis_constr_nargs indsp in PrintingLet.active (indsp,lc)
let force_if ci =
  let indsp = ci.ci_ind in
  let lc = mis_constr_nargs indsp in PrintingIf.active (indsp,lc)

(* Options for printing or not wildcard and synthetisable types *)

open Goptions

let wildcard_value = ref true
let force_wildcard () = !wildcard_value

let _ = declare_bool_option 
	  { optsync  = true;
	    optname  = "forced wildcard";
	    optkey   = SecondaryTable ("Printing","Wildcard");
	    optread  = force_wildcard;
	    optwrite = (:=) wildcard_value }

let synth_type_value = ref true
let synthetize_type () = !synth_type_value

let _ = declare_bool_option 
	  { optsync  = true;
	    optname  = "synthesizability";
	    optkey   = SecondaryTable ("Printing","Synth");
	    optread  = synthetize_type;
	    optwrite = (:=) synth_type_value }

(* Auxiliary function for MutCase printing *)
(* [computable] tries to tell if the predicate typing the result is inferable*)

let computable p k =
    (* We first remove as many lambda as the arity, then we look
       if it remains a lambda for a dependent elimination. This function
       works for normal eta-expanded term. For non eta-expanded or
       non-normal terms, it may affirm the pred is synthetisable
       because of an undetected ultimate dependent variable in the second
       clause, or else, it may affirms the pred non synthetisable
       because of a non normal term in the fourth clause.
       A solution could be to store, in the MutCase, the eta-expanded
       normal form of pred to decide if it depends on its variables

       Lorsque le pr�dicat est d�pendant de mani�re certaine, on
       ne d�clare pas le pr�dicat synth�tisable (m�me si la
       variable d�pendante ne l'est pas effectivement) parce que
       sinon on perd la r�ciprocit� de la synth�se (qui, lui,
       engendrera un pr�dicat non d�pendant) *)

  (nb_lam p = k+1)
  &&
  let _,ccl = decompose_lam p in 
  noccur_between 1 (k+1) ccl



let lookup_name_as_renamed env t s =
  let rec lookup avoid env_names n c = match kind_of_term c with
    | Prod (name,_,c') ->
	(match concrete_name env avoid env_names name c' with
           | (Some id,avoid') -> 
	       if id=s then (Some n) 
	       else lookup avoid' (add_name (Name id) env_names) (n+1) c'
	   | (None,avoid')    -> lookup avoid' env_names (n+1) (pop c'))
    | LetIn (name,_,_,c') ->
	(match concrete_name env avoid env_names name c' with
           | (Some id,avoid') -> 
	       if id=s then (Some n) 
	       else lookup avoid' (add_name (Name id) env_names) (n+1) c'
	   | (None,avoid')    -> lookup avoid' env_names (n+1) (pop c'))
    | Cast (c,_) -> lookup avoid env_names n c
    | _ -> None
  in lookup (ids_of_named_context (named_context env)) empty_names_context 1 t

let lookup_index_as_renamed env t n =
  let rec lookup n d c = match kind_of_term c with
    | Prod (name,_,c') ->
	  (match concrete_name env [] empty_names_context name c' with
               (Some _,_) -> lookup n (d+1) c'
             | (None  ,_) -> if n=1 then Some d else lookup (n-1) (d+1) c')
    | LetIn (name,_,_,c') ->
	  (match concrete_name env [] empty_names_context name c' with
             | (Some _,_) -> lookup n (d+1) c'
             | (None  ,_) -> if n=1 then Some d else lookup (n-1) (d+1) c')
    | Cast (c,_) -> lookup n d c
    | _ -> None
  in lookup n 1 t

let rec detype tenv avoid env t =
  match kind_of_term (collapse_appl t) with
    | Rel n ->
      (try match lookup_name_of_rel n env with
	 | Name id   -> RVar (dummy_loc, id)
	 | Anonymous -> anomaly "detype: index to an anonymous variable"
       with Not_found ->
	 let s = "_UNBOUND_REL_"^(string_of_int n)
	 in RVar (dummy_loc, id_of_string s))
    | Meta n -> RMeta (dummy_loc, n)
    | Var id ->
	(try
	  let _ = Global.lookup_named id in RRef (dummy_loc, VarRef id)
	 with _ ->
	  RVar (dummy_loc, id))
    | Sort (Prop c) -> RSort (dummy_loc,RProp c)
    | Sort (Type u) -> RSort (dummy_loc,RType (Some u))
    | Cast (c1,c2) ->
	RCast(dummy_loc,detype tenv avoid env c1,
              detype tenv avoid env c2)
    | Prod (na,ty,c) -> detype_binder tenv BProd avoid env na ty c
    | Lambda (na,ty,c) -> detype_binder tenv BLambda avoid env na ty c
    | LetIn (na,b,_,c) -> detype_binder tenv BLetIn avoid env na b c
    | App (f,args) ->
	RApp (dummy_loc,detype tenv avoid env f,
              array_map_to_list (detype tenv avoid env) args)
    | Const sp -> RRef (dummy_loc, ConstRef sp)
    | Evar (ev,cl) ->
	let f = REvar (dummy_loc, ev) in
	RApp (dummy_loc, f,
              List.map (detype tenv avoid env) (Array.to_list cl))
    | Ind ind_sp ->
	RRef (dummy_loc, IndRef ind_sp)
    | Construct cstr_sp ->
	RRef (dummy_loc, ConstructRef cstr_sp)
    | Case (annot,p,c,bl) ->
	let synth_type = synthetize_type () in
	let tomatch = detype tenv avoid env c in
	let indsp = annot.ci_ind in
        let considl = annot.ci_pp_info.cnames in
        let k = annot.ci_pp_info.ind_nargs in
	let consnargsl = mis_constr_nargs_env tenv indsp in
	let pred = 
	  if synth_type & computable p k & considl <> [||] then
	    None
	  else 
	    Some (detype tenv avoid env p) in
	let constructs = 
	  Array.init (Array.length considl) (fun i -> (indsp,i+1)) in
	let eqnv =
	  array_map3 (detype_eqn tenv avoid env) constructs consnargsl bl in
	let eqnl = Array.to_list eqnv in
	let tag =
	  try 
	    if PrintingLet.active (indsp,consnargsl) then
	      LetStyle
	    else if PrintingIf.active (indsp,consnargsl) then 
	      IfStyle
	    else 
	      annot.ci_pp_info.style
	  with Not_found -> annot.ci_pp_info.style
	in 
	if tag = RegularStyle then
	  RCases (dummy_loc,pred,[tomatch],eqnl)
	else
	  let rec remove_type n c = if n = 0 then c else
	    match c with
	      | RLambda (loc,na,t,c) ->
		  let h = RHole (loc,AbstractionType na) in
		  RLambda (loc,na,h,remove_type (n-1) c)
	      | RLetIn (loc,na,b,c) ->
		  RLetIn (loc,na,b,remove_type (n-1) c)
	      | c -> c in
	  let bl = Array.map (detype tenv avoid env) bl in
	  let bl = array_map2 remove_type consnargsl bl in
	  ROrderedCase (dummy_loc,tag,pred,tomatch,bl)
	
    | Fix (nvn,recdef) -> detype_fix tenv avoid env (RFix nvn) recdef
    | CoFix (n,recdef) -> detype_fix tenv avoid env (RCoFix n) recdef

and detype_fix tenv avoid env fixkind (names,tys,bodies) =
  let def_avoid, def_env, lfi =
    Array.fold_left
      (fun (avoid, env, l) na ->
	 let id = next_name_away na avoid in 
	 (id::avoid, add_name (Name id) env, id::l))
      (avoid, env, []) names in
  RRec(dummy_loc,fixkind,Array.of_list (List.rev lfi),
       Array.map (detype tenv avoid env) tys,
       Array.map (detype tenv def_avoid def_env) bodies)


and detype_eqn tenv avoid env constr construct_nargs branch =
  let make_pat x avoid env b ids =
    if force_wildcard () & noccurn 1 b then
      PatVar (dummy_loc,Anonymous),avoid,(add_name Anonymous env),ids
    else 
      let id = next_name_away_with_default "x" x avoid in
      PatVar (dummy_loc,Name id),id::avoid,(add_name (Name id) env),id::ids
  in
  let rec buildrec ids patlist avoid env n b =
    if n=0 then
      (dummy_loc, ids, 
       [PatCstr(dummy_loc, constr, List.rev patlist,Anonymous)],
       detype tenv avoid env b)
    else
      match kind_of_term b with
	| Lambda (x,_,b) -> 
	    let pat,new_avoid,new_env,new_ids = make_pat x avoid env b ids in
            buildrec new_ids (pat::patlist) new_avoid new_env (n-1) b

	| LetIn (x,_,_,b) -> 
	    let pat,new_avoid,new_env,new_ids = make_pat x avoid env b ids in
            buildrec new_ids (pat::patlist) new_avoid new_env (n-1) b

	| Cast (c,_) ->    (* Oui, il y a parfois des cast *)
	    buildrec ids patlist avoid env n c

	| _ -> (* eta-expansion : n'arrivera plus lorsque tous les
                  termes seront construits � partir de la syntaxe Cases *)
            (* nommage de la nouvelle variable *)
	    let new_b = applist (lift 1 b, [mkRel 1]) in
            let pat,new_avoid,new_env,new_ids =
	      make_pat Anonymous avoid env new_b ids in
	    buildrec new_ids (pat::patlist) new_avoid new_env (n-1) new_b
	  
  in 
  buildrec [] [] avoid env construct_nargs branch

and detype_binder tenv bk avoid env na ty c =
  let na',avoid' =
    if bk = BLetIn then concrete_let_name tenv avoid env na c
    else
      match concrete_name tenv avoid env na c with
	| (Some id,l') -> (Name id), l'
	| (None,l')    -> Anonymous, l' in
  let r =  detype tenv avoid' (add_name na' env) c in
  match bk with
    | BProd -> RProd (dummy_loc, na',detype tenv [] env ty, r)
    | BLambda -> RLambda (dummy_loc, na',detype tenv [] env ty, r)
    | BLetIn -> RLetIn (dummy_loc, na',detype tenv [] env ty, r)
