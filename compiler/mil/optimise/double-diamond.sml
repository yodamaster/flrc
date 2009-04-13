(* The Intel P to C/Pillar Compiler *)
(* Copyright (C) Intel Corporation, May 2008 *)
(* Description: MIL Double Diamond implementation. *)

(* Double Diamond Reduction:
 *
 * Algorithm:
 * =========
 *
 *  XXX EB: Check and improve the algorithm description
 *
 *  for each cfg
 *  loop () =
 *   worklist = {} 
 *   changed := true
 *   labels <- list all labels in cfg
 *   for every variable v bound by a label with multiple in-edges
 *    if all uses of label are in RhsSeqQuery instructions
 *      changed := true
 *      split the in edges of block
 *      replace v with a new variable b in the inarg list
 *      replace all the RhsSetQuery instructions with RhsSimple b
 *      replace the corresponding out arg vi of the new predecessor block bi
 *      with a new variable xi
 *      add an instruction xi = RhsSetQuery vi to block bi
 *      add all new and modified instructions to the worklist
 *   call the simplifier on the worklist
 *  if changed then loop () else ()
 *
 * Double Diamond Reduction Example:
 * ================================
 * 
 * Before the reduction                      After the reduction
 * --------------------                      -------------------
 * 
 * L00:                                 |    L00:          
 *  goto L10 (v00)                      |     goto L10 (v00)
 *                                      |                  
 * L01:                                 |    L01:          
 *  goto L10 (v01)                      |     goto L10 (v01)
 *                                      |
 * L10 (v10):    < L2 predecessor       |    L10 (v10):
 *  goto L2 (v10)                       |     goto L10_to_L2 (v10)
 *                                      |                 
 * L11 (v11):    < L2 predecessor       |    L11 (v11):
 *  goto L2 (v11)                       |     goto L11_to_L2 (v11)
 *                                      |
 *                                      |    L10_to_L2 (v102) < New split block
 *                                      |     x1 = (v102)?    < RhsPSetQuery
 *                                      |     goto L2 (x1)    
 *                                      |
 *                                      |    L11_to_L2 (v112) < New split block
 *                                      |     x2 = (v112)?    < RhsPSetQuery
 *                                      |     goto L2 (x2)   
 *                                      |    
 * L2 (v)         < v bound by label L2 |    L2 (b1)     
 *  b = (v)?     < RhsPSetQuery         |     b = b1  < RhsSimple
 *
 *)

signature MIL_DBL_DIAMOND = 
sig
  val pass : (BothMil.t, BothMil.t) Pass.t
end
                           
structure MilDblDiamond :> MIL_DBL_DIAMOND = 
struct

  val passname = "MilDblDiamond"

  val stats = [("SQLifted", "PSetQueries lifted")]

  (* Aliases *)
  structure PD    = PassData
  structure MOU   = MilOptUtils
  structure U     = Utils
  structure WS    = IMil.WorkSet
  structure Instr = IMil.Instr
  structure Block = IMil.Block
                    
  type block = IMil.block
               
  (* Reports a fail message and exit the program.
   * param f: The function name.
   * param s: the messagse. *)
  fun fail (f, m) = Fail.fail ("double-diamond.sml", f, m)
                    
  val (debugPassD, debugPass) =
      Config.Debug.mk (passname, "debug the Mil double diamond pass")

  (* Print a message if debug mode is on. *)
  fun debug (d : PD.t, m : string) =
      if debugPass (PD.getConfig d) then
        print (passname ^ ": " ^ m ^ "\n")
      else ()
           
  (* Fix the predecessor block.
   * Each kth precedcessor looks like:
   *   Lk (v1, ..., vi, ..., vn)
   *     goto L (v1, ..., vi, ..., vn) 
   * - add vi' = RhsSeqQuery (vi)
   * - change goto to L (v1, ..., vi', ..., vn) *)
  fun fixPredecessor (imil : IMil.t, wl : WS.ws, blk : block, varIndex : int) =
      let
        (* Add "vi' = RhsSeqQuery (vi)" into the block. *)
        val parameters = Block.getParameters (imil, blk)
        val vi : Mil.variable = Vector.sub (parameters, varIndex)
        val vi' : Mil.variable = IMil.newVar (imil, "mdd_vii", 
                                              MilDefinitions.Bool.t, false)
        val opand : Mil.operand = Mil.SVariable (vi)
        val newMilInstr = Mil.I {dest=SOME vi', rhs=Mil.RhsPSetQuery (opand)}
        val newInstr : IMil.instr = Block.append (imil, blk, newMilInstr)
        (* Add newInstr to worklist. *)
        val () = WS.addInstr (wl, newInstr)
        (* Change "Goto L (v1, ..., vi, ...)" to "Goto L (v1, ..., vi', ...) *)
        val transferInstr : IMil.instr = Block.getTransfer (imil, blk)
        val (args, block) = case MOU.iinstrToTransfer (imil, transferInstr)
                             of SOME (Mil.TGoto (Mil.T {block, arguments})) => 
                                (arguments, block)
                              | _ => fail ("fixPredecessor", 
                                           "Block optional transfer is "^
                                           "not TGoto")
        val newArguments = U.vectorUpdate (args, varIndex, Mil.SVariable (vi'))
        val newTarget = Mil.T {block=block, arguments=newArguments} 
        val newTransfer = Mil.TGoto newTarget
        (* Add newInstr to worklist *)
        val () = WS.addInstr (wl, transferInstr)
      in 
        Block.replaceTransfer (imil, blk, newTransfer)
      end
        
  (* Replace a RhsPSetQuery (use) instruction by a RhsPSimple (newVar) one.
   * param imil: The IMil program.
   * param wl: The work list to keep track of the modified instructions.
   * param use: The use (in the instruction to be replaced)
   * param newVar: the new variable. *)
  fun replacePSetQuery (imil, wl, use, newVar) = 
      let
        val iinstr = case MOU.useToIInstr (imil, use)
                      of SOME iinstr => iinstr
                       | NONE => fail ("replacePSetQuery", 
                                       "Invalid use");
        (*  XXX EB:  Should it  become an  iinstrToDest  function into
         * MilOptUtils? *)
        val Mil.I {dest=d,...} = case MOU.iinstrToInstr (imil, iinstr)
                                  of SOME x => x
                                   | NONE => fail ("replacePSetQuery",
                                                   "Invalid mil instruction")
        val newInstr = Mil.I {dest = d, 
                              rhs  = Mil.RhsSimple (Mil.SVariable (newVar))}
        val () = WS.addInstr (wl, iinstr)
      in 
        IMil.Instr.replaceInstruction (imil, iinstr, newInstr)
      end
      
  (* Process the variable v. Creates a new variable, and updates
   * the uses of v (replacing the RhsPSetQuery instructions by
   * RhsSimple instructions). 
   * param imil: The IMil program.
   * param label: The entry label, at the beginning of the block.
   * param varIndex: The  index of  the element  containing v  in the
   *       label argument vector.  
   * param v: The Mil variable to be processed.
   * param predecessors: The list of predecessor blocks, resulting from 
   *                     the in edge spliting. 
   * returns The new variable. *)
  fun processVariable (imil : IMil.t, wl : WS.ws, label : Mil.label, 
                       varIndex : int, v : Mil.variable, 
                       predecessors : block list) : Mil.variable =  
      let
        (* Replace v with a new variable b in the inarg list *)
        val newVar = IMil.newVar (imil, "mdd", MilDefinitions.Bool.t, false)
        (* Replace the RhsSetQuery (v) instructions by RhsSimple (newVar) *)
        val uses = IMil.Use.getUses (imil, v)
	fun doOne (use) = replacePSetQuery (imil, wl, use, newVar)
        val () = Vector.foreach (uses, doOne)
        (* Add the RhsPSetQuery instruction and fix each of the predecessors.
         *   Lk (v1, ..., vi, ..., vn)
         *     goto L (v1, ..., vi, ..., vn) 
         * - add vi' = RhsSeqQuery (vi)
         * - change goto to L (v1, ..., vi', ..., vn) *)
	fun doOne (blk) = fixPredecessor (imil, wl, blk, varIndex)
        val () = List.foreach (predecessors, doOne)
      in 
        newVar
      end

  (* Check if the use is a non RhsPSetQuery.
   * param imil: The IMil program.
   * param use: The use to be checked. 
   * returns true if use is in the format dest <- RhsPSetQuery (use),
   *         otherwise returns false. *)
  fun useIsRhsPSetQuery (imil : IMil.t, use : IMil.use) : bool =
      case MOU.useToInstr (imil, use)
       of  SOME (Mil.I {rhs=Mil.RhsPSetQuery _, ...}) => true
	 | _ => false

  (* Check if all uses of variable v are in the format 
   * dest <- RhsPSetQuery (use).
   * param imil: The IMil program.
   * param v: The variable v. 
   * returns true if all uses of  variable v are in the format 
   *         dest <- RhsPSetQuery (use), return false otherwise. *)
  fun allUsesAreRhsPSetQuery (d : PD.t, imil : IMil.t,
                              v : Mil.variable) : bool = 
      let
        val uses : IMil.use Vector.t = IMil.Use.getUses (imil, v)
        val allRhsPSetQuery = 
            Vector.forall (uses, fn (u) => useIsRhsPSetQuery (imil, u))
        val () = if (allRhsPSetQuery) then
                   debug (d, "  - [OK]: All uses are RhsPSetQuery.")
                 else
                   debug (d, "  - [FAILED]: Has an use with non RhsPSetQuery.")
      in 
        allRhsPSetQuery
      end

  (* Check if the IMil block has multiple input edges.
   * param imil: The imil representation. 
   * param block: The block to check. 
   * returns true if IMil block has multiple input edges, otherwise,
   * returns false. *)
  fun isMultipleInEdgeBlock (imil : IMil.t, block : IMil.block) : bool =
      let
        val inEdges : (block * block) list = Block.inEdges (imil, block);
      in
        length (inEdges) > 1
      end

  (* Apply the double diamond reduction to a given label.
   * If label has  multiple in-edges, process each of  the variables v
   * bound by the label.
   * param d: Mil optimizing pass data
   * param imil: The imil program containing the label.
   * param wl:  A work  list to keep  track of instructions  that were
   *            modified/created during the optimization.
   * param labelInstr: The label to be processed.
   * return: true  if  any  variable was  updated,  otherwise  returns
   *         default changed flag. *)
  fun processLabel (d : PD.t, imil : IMil.t, wl : WS.ws, 
                    labelInstr : IMil.instr) : bool = 
      let
        val (label, vars) = case MOU.iinstrToLabel (imil, labelInstr)
                             of NONE => fail ("processLabel","Invalid label")
                              | SOME x => x
        (* splitBlocks  contains  an  optional list  of  predecessors
         * blocks, resulting from the edge spliting. *)
        val splitBlocks = ref NONE
        val changed = ref false
        val block = IMil.Instr.getBlock (imil, labelInstr);
        val () = debug (d, "- Processing label \""^
                           Identifier.labelString (label)^"\".")
        (* Check  if the input  edges where previously split.  If not,
         * split it and update the splitBlocks reference. *)
        fun splitInputEdges () : (block list) option =
            Try.try
              (fn () => 
                  case !splitBlocks
                   of SOME preds => preds
                    | NONE =>
                      let
                        val (preds, cut) = Block.splitInEdges (imil, block)
                        (* If there is an input cut edge, raise an
                         * exception. XXX EB: Should be tested before. *)
                        val () = Try.require (not cut)
                        val () = splitBlocks := SOME preds
                        fun addLabelToWL (blk) = 
                            WS.addInstr (wl, IMil.Block.getLabel (imil, blk))
                        val () = List.foreach (preds, addLabelToWL)
                      in preds
                      end)
              
        (* Check  if all uses  of the variable  v (bounded by  a label
         * with    multiple     in-edges)    are    in    RhsPSetQuery
         * instructions. If so, processes the variable and returns
         * the new one, otherwise return the unmodified variable. *)
        fun checkAndProcessVariable (i : int, v : Mil.variable) =
            Try.try 
              (fn () => 
                  let
                    val () = debug (d, "  - check and process variable \""
                                       ^Identifier.variableString'(v)^"\".")
                  in
                    if ( allUsesAreRhsPSetQuery (d, imil, v) ) then
                      let
                        val () = debug (d, "     - all uses are RhsPSetQuery.")
                        (* XXX EB: TODO:  Check if block has input cut
                         * edge before spliting the input edges.
                         * val () = Try.require (not hasInputCut (imil, block))
                         *)
                        (* splitInputEdges throws  an exception if one
                         * of the input edges is a cut. *)
                        val predecessors = Try.<- (splitInputEdges ())
                        val () = changed := true
                        val () = PD.click (d, "SQLifted")
                      in
                        processVariable (imil, wl, label, i, v, predecessors)
                      end
                    else 
                      v 
                  end)
            
        (* Try  to process  the  variables.   If the  splitInputEdges
         * (inside  the checkAndProcessVarible)  process  finds a  cut
         * edge, it fails. *)
        val _ = 
            Try.try
            (fn () => 
                let
                  val () = Try.require (isMultipleInEdgeBlock (imil, block))
                  val () = debug (d, "  - Label has multiple input edges.");
                  (* CheckAndProcessVariable fails  if the one or more of the
                   * input edges is a cut. *)
                  val newVars = 
                      Vector.mapi (vars, (Try.<- o checkAndProcessVariable))
                  val () = debug (d, "  - Replacing label.");
                  (* The labelInstr will be modified. Add it to the WS. *)
                  val () = WS.addInstr (wl, labelInstr)
                in 
                  Instr.replaceMil (imil, labelInstr, IMil.MLabel (label, 
                                                                   newVars))
                end)
      in
        !changed
      end

  (* Process a single cfg.  Apply the double diamond reduction to each
   * label in the imil program.
   * param d: Mil optimizing pass data.
   * param imil: The imil representation. *)
  fun processCfg (d : PD.t, imil : IMil.t, cfg : IMil.cfg) : unit = 
      let
        val wl = WS.new ()
        val labels : IMil.instr list = IMil.Enumerate.Cfg.labels (imil, cfg)
        fun doLabel (l, c) = c orelse processLabel (d, imil, wl, l)
        val changed = List.fold (labels, false, doLabel)
        (* Update the imil internal representation *)
        val () = MilCFGSimplify.function (d, imil, cfg)
        val () = MilSimplify.simplify (d, imil, wl)
      in 
        (* Repeat while there are changes. *)
        if (changed) then 
          processCfg (d, imil, cfg)
        else ()
      end

  (* Process all the cfgs.
   * param d: Mil optimizing pass data.
   * param imil: The imil representation. *)
  fun processCfgs (d : PD.t, imil : IMil.t) : unit = 
      let
        val cfgs = IMil.Enumerate.T.cfgs (imil)
      in
        List.foreach (cfgs, fn (cfg) => processCfg (d, imil, cfg))
      end
      
  (* Perform the double  diamond reduction  in the  imil intermediate
   * representation.
   * param d: Mil optimizing pass data
   * param imil: The imil representation. *)
  fun program (imil : IMil.t, pd : PD.t) : unit = 
      let
        val () = debug (pd, " - Starting the double diamond reduction...")
        val () = processCfgs (pd, imil)
        val () = PD.report (pd, passname)
      in ()
      end

  val description = {name        = passname,
                     description = "Lift set queries above phis",
                     inIr        = BothMil.irHelpers,
                     outIr       = BothMil.irHelpers,
                     mustBeAfter = [],
                     stats       = stats}

  val associates = {controls  = [],
                    debugs    = [debugPassD],
                    features  = [],
                    subPasses = []}

  val pass =
      Pass.mkOptPass (description, associates, BothMil.mkIMilPass program)

end (* end of structure MilDblDiamond *)