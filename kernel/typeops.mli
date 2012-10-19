(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Names
open Univ
open Term
open Environ
open Entries
open Declarations

(** {6 Typing functions (not yet tagged as safe) }
    
    They return unsafe judgments that are "in context" of a set of 
    (local) universe variables (the ones that appear in the term)
    and associated constraints. In case of polymorphic definitions,
    these variables and constraints will be generalized.
 *)


val infer      : env -> constr       -> unsafe_judgment in_universe_context_set
val infer_v    : env -> constr array -> 
  unsafe_judgment array in_universe_context_set
val infer_type : env -> types        -> 
  unsafe_type_judgment in_universe_context_set

val infer_local_decls :
  env -> (identifier * local_entry) list
    -> (env * rel_context) in_universe_context_set

(** {6 Basic operations of the typing machine. } *)

(** If [j] is the judgement {% $ %}c:t{% $ %}, then [assumption_of_judgement env j]
   returns the type {% $ %}c{% $ %}, checking that {% $ %}t{% $ %} is a sort. *)

val assumption_of_judgment :  env -> unsafe_judgment -> types
val type_judgment          :  env -> unsafe_judgment -> unsafe_type_judgment

(** {6 Type of sorts. } *)
val judge_of_prop : unsafe_judgment
val judge_of_set  : unsafe_judgment
val judge_of_prop_contents  : contents -> unsafe_judgment
val judge_of_type           : universe -> unsafe_judgment

(** {6 Type of a bound variable. } *)
val judge_of_relative : env -> int -> unsafe_judgment

(** {6 Type of variables } *)
val judge_of_variable : env -> variable -> unsafe_judgment

(** {6 type of a constant } *)
val judge_of_constant : env -> constant puniverses -> unsafe_judgment constrained

(* val judge_of_constant_knowing_parameters : *)
(*   env -> constant -> unsafe_judgment array -> unsafe_judgment *)

(** {6 Type of application. } *)
val judge_of_apply :
  env -> unsafe_judgment -> unsafe_judgment array
    -> unsafe_judgment constrained

(** {6 Type of an abstraction. } *)
val judge_of_abstraction :
  env -> name -> unsafe_type_judgment -> unsafe_judgment
    -> unsafe_judgment

(** {6 Type of a product. } *)
val judge_of_product :
  env -> name -> unsafe_type_judgment -> unsafe_type_judgment
    -> unsafe_judgment

(** s Type of a let in. *)
val judge_of_letin :
  env -> name -> unsafe_judgment -> unsafe_type_judgment -> unsafe_judgment
    -> unsafe_judgment

(** {6 Type of a cast. } *)
val judge_of_cast :
  env -> unsafe_judgment -> cast_kind -> unsafe_type_judgment ->
  unsafe_judgment constrained

(** {6 Inductive types. } *)

val judge_of_inductive : env -> inductive puniverses -> unsafe_judgment constrained

(* val judge_of_inductive_knowing_parameters : *)
(*   env -> inductive -> unsafe_judgment array -> unsafe_judgment *)

val judge_of_constructor : env -> constructor puniverses -> unsafe_judgment constrained

(** {6 Type of Cases. } *)
val judge_of_case : env -> case_info
  -> unsafe_judgment -> unsafe_judgment -> unsafe_judgment array
    -> unsafe_judgment constrained

(** Typecheck general fixpoint (not checking guard conditions) *)
val type_fixpoint : env -> name array -> types array
    -> unsafe_judgment array -> constraints

(** Kernel safe typing but applicable to partial proofs *)
val typing : env -> constr -> unsafe_judgment in_universe_context_set

val type_of_constant : env -> constant puniverses -> types constrained

val type_of_constant_inenv : env -> constant puniverses -> types

val type_of_constant_knowing_parameters : env -> types -> types array -> types


