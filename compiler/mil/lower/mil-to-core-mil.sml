(* The Intel P to C/Pillar Compiler *)
(* Copyright (C) Intel Corporation *)

signature MIL_TO_CORE_MIL = 
sig
  val pass : (BothMil.t, BothMil.t) Pass.t
end

functor MilToCoreMilF(val passname : string
                      val desc : string
                      val lowerPTypes : bool
                      val lowerPSums : bool
                      val lowerPFunctions : bool
                      val lowerPRefs : bool) :> MIL_TO_CORE_MIL = 
struct
  val passname = passname

  val fail = fn (fname, msg) => Fail.fail (passname, fname, msg)

  structure I = Identifier
  structure IM = I.Manager
  structure ND = Identifier.NameDict
  structure LD = Identifier.LabelDict
  structure M = Mil
  structure MU = MilUtils
  structure MSTM = MU.SymbolTableManager
  structure MTT = MilType.Typer
  structure POM = PObjectModel

  datatype state = S of {stm : M.symbolTableManager}

  local
    val get = fn sel => fn (S t) => sel t
  in
  val stateGetStm = get #stm
  end

  fun stateGetSymbolInfo s = I.SymbolInfo.SiManager (stateGetStm s)

  fun getVarTyp (s, v) = MSTM.variableTyp (stateGetStm s, v)

  val nextBlock = 
   fn state => 
      let
        val stm = stateGetStm state
        val l = IM.labelFresh stm
      in l
      end

  val namedVar = 
   fn (state, s, t, b)  => 
      let
        val stm = stateGetStm state
        val v = MSTM.variableFresh (stm, s, t, b)
      in v
      end

  val relatedVar = 
   fn (state, vo, s, t, b)  => 
      let
        val stm = stateGetStm state
        val v = MSTM.variableRelated (stm, vo, s, t, b)
      in v
      end

  val cloneVar = 
   fn (state, v)  => 
      let
        val stm = stateGetStm state
        val v = IM.variableClone (stm, v)
      in v
      end

  datatype env = E of {config : Config.t}

  fun envGetConfig (E {config, ...}) = config

  val layoutOperand = 
   fn (state, env, oper)  => 
      let
        val stm = stateGetStm state
        val si = I.SymbolInfo.SiManager stm
        val config = envGetConfig env
        val l = MilLayout.layoutOperand (config, si, oper)
      in l
      end

  structure MSS = MilStreamF(type state = state
                             type env = env
                             val toConfig = envGetConfig
                             val getStm = stateGetStm
                             val indent = 2)
  structure MS = MSS.Stream
  structure MSU = MSS.Utils

  structure Chat = ChatF(struct type env = env
                                val extract = envGetConfig
                                val name = passname
                                val indent = 2 
                         end)

  val rec operToVar = 
   fn (state, env, oper) =>
      case oper
       of M.SVariable v => v
        | M.SConstant _ => 
          let
            val l = layoutOperand (state, env, oper)
            val s = Layout.toString l
          in
            fail ("operToVar", "Not a var: " ^ s)
          end

  val wordSize = fn env => Config.targetWordSize' (envGetConfig env)

  val label = 
   fn (state, env, (l, vs)) => (env, NONE)

  val rec doTyps =
   fn (state, env, ts) => Vector.map (ts, fn t => doTyp (state, env, t))
  and rec doTyp = 
   fn (state, env, t) => 
      let 
        val typs = fn ts => doTyps (state, env, ts)
        val typ = fn t => doTyp (state, env, t)
        val t = 
            case t
             of M.TAny => t
              | M.TAnyS _ => t
              | M.TPtr => t
              | M.TRef => t
              | M.TBits _ => t
              | M.TNone => t
              | M.TRat => t
              | M.TInteger => t
              | M.TName => t
              | M.TIntegral _ => t
              | M.TFloat => t
              | M.TDouble => t
              | M.TViVector _ => t
              | M.TViMask _ => t
              | M.TCode {cc, args, ress} =>
                let
                  val cc = MU.CallConv.map (cc, typ)
                  val aTyps = typs args
                  val rTyps = typs ress
                  val t =
                      case cc
                       of M.CcClosure {cls, ...} =>
                          if lowerPFunctions then
                            POM.Function.codeTyp (cls, aTyps, rTyps)
                          else
                            M.TCode {cc = cc, args = aTyps, ress = rTyps}
                        | _ => M.TCode {cc = cc, args = aTyps, ress = rTyps}
                in t
                end
              | M.TTuple {pok, fixed, array} =>
                let
                  fun typVar (t, v) = (typ t, v)
                  val tvs = Vector.map (fixed, typVar)
                  val tvo = Option.map (array, typVar)
                  val t = M.TTuple {pok = pok, fixed = tvs, array = tvo}
                in t
                end
              | M.TIdx => t
              | M.TContinuation ts => M.TContinuation (typs ts)
              | M.TThunk t => M.TThunk (typ t)
              | M.TPAny => t
              | M.TPFunction {args, ress} =>
                let
                  val args = typs args
                  val ress = typs ress
                  val t =
                      if lowerPFunctions then
                        POM.Function.closureTyp (args, ress)
                      else
                        M.TPFunction {args = args, ress = ress}
                in t
                end
              | M.TPSum nts =>
                let
                  val nts = ND.map (nts, fn (_, t) => typ t)
                  val t =
                      if lowerPSums then
                        POM.Sum.loweredTyp nts
                      else
                        M.TPSum nts
                in t
                end
              | M.TPType {kind, over} =>
                let
                  val over = typ over
                  val t =
                      if lowerPTypes then
                        case kind
                         of M.TkI => POM.Type.loweredTyp over
                          | M.TkE => POM.OptionSet.loweredTyp over
                      else
                        M.TPType {kind = kind, over = over}
                in t
                end
              | M.TPRef t =>
                let
                  val t = typ t
                  val t =
                      if lowerPRefs then
                        POM.Ref.loweredTyp t
                      else
                        M.TPRef (typ t)
                in t
                end
      in t
      end

  val tupleProjectF = 
   fn (state, env, dest, v, j, td) =>
      let
        val tf = M.TF {tupDesc = td, tup = v, field = M.FiFixed j}
        val s = MS.instrMk (state, env, dest, M.RhsTupleSub tf)
      in s
      end
      
  val doPSetEmpty =  
   fn (state, env, ()) => POM.OptionSet.empty (envGetConfig env)

  fun doPTypePH (state, env, ()) = POM.Type.placeHolder

  fun doPFunMk (state, env, fks) =
      POM.Function.mkUninit (envGetConfig env, fks)

  fun doPFunInit (state, env, dest, cls, code, fvs) =
      let
        val c = envGetConfig env
        val code =
            case code
             of NONE => M.SConstant (MU.UIntp.zero c)
              | SOME v => M.SVariable v
      in
        case cls
         of NONE =>
          (* Create the closure *)
            MS.instrMk (state, env, dest, POM.Function.mkInit (c, code, fvs))
          (* Closure already exists, initialise it *)
          | SOME cls =>
            let
              val rhss = POM.Function.init (c, cls, code, fvs)
              fun doOne rhs = MS.doRhs (state, env, rhs)
              val s = MS.seqn (state, env, List.map (rhss, doOne))
            in s
            end
      end

  fun doPFunGetFv (state, env, (fvs, cls, idx)) =
      POM.Function.getFv (envGetConfig env, fvs, cls, idx)

  val doPSetNew = 
   fn (state, env, oper) => POM.OptionSet.mk (envGetConfig env, oper)

  fun doPSetGet (state, env, v) = POM.OptionSet.get (envGetConfig env, v)

  fun doPSetCond (state, env, dest, bool, ofVal) =
      let 
        val c = envGetConfig env
        val (ps, vF, asF, vT, asT) =
            case dest
             of NONE =>
                (Vector.new0 (), NONE, Vector.new0 (), NONE, Vector.new0 ())
              | SOME v =>
                let
                  val vF = cloneVar (state, v)
                  val vT = cloneVar (state, v)
                in
                  (Vector.new1 v, SOME vF, Vector.new1 (M.SVariable vF),
                   SOME vT, Vector.new1 (M.SVariable vT))
                end
        val sFalse = MS.instrMk (state, env, vF, POM.OptionSet.empty c)
        val sTrue = MS.instrMk (state, env, vT, POM.OptionSet.mk (c, ofVal))
        val s = MSU.ifTrue (state, env, ps, bool, (sTrue, asT), (sFalse, asF))
      in s
      end

  fun doPSetQuery (state, env, dest, v) =
      let 
        val c = envGetConfig env
        val (rhs, t, compConst) = POM.OptionSet.query (c, v)
        val vc = relatedVar (state, v, "_ptr", t, false)
        val s1 = MS.bindRhs (state, env, vc, rhs)
        val (ps, asF, asT) =
            case dest
             of NONE => (Vector.new0 (), Vector.new0 (), Vector.new0 ())
              | SOME v => (Vector.new1 v,
                           Vector.new1 (M.SConstant (MU.Bool.F c)),
                           Vector.new1 (M.SConstant (MU.Bool.T c)))
        val s2 = MSU.ifConst (state, env, ps, M.SVariable vc, compConst,
                              (MS.new (state, env), asF),
                              (MS.new (state, env), asT))
        val s = MS.seq (state, env, s1, s2)
      in s
      end

  val doPSum = 
   fn (state, env, (nm, fk, oper)) =>
      POM.Sum.mk (envGetConfig env, nm, fk, oper)

  fun doPSumProj (state, env, (fk, v, _)) =
      POM.Sum.getVal (envGetConfig env, v, fk)

  fun lowerToRhs (state, env, lower, doIt, dest, args) =
      if lower then
        let
          val rhs = doIt (state, env, args)
          val s = MS.instrMk (state, env, dest, rhs)
        in SOME s
        end
      else
        NONE

  val instr = 
   fn (state, env, i) => 
      let
        val M.I {dest, rhs} = i
        val res = 
            case rhs
             of M.RhsSimple (M.SConstant M.COptionSetEmpty) => 
                lowerToRhs (state, env, lowerPTypes, doPSetEmpty, dest, ())
              | M.RhsSimple (M.SConstant M.CTypePH) =>
                lowerToRhs (state, env, lowerPTypes, doPTypePH, dest, ())
              | M.RhsPFunctionMk {fvs} =>
                lowerToRhs (state, env, lowerPFunctions, doPFunMk, dest, fvs)
              | M.RhsPFunctionInit {cls, code, fvs} => 
                if lowerPFunctions then
                  SOME (doPFunInit (state, env, dest, cls, code, fvs))
                else
                  NONE
              | M.RhsPFunctionGetFv {fvs, cls, idx} => 
                lowerToRhs (state, env, lowerPFunctions, doPFunGetFv, dest,
                            (fvs, cls, idx))
              | M.RhsPSetNew oper => 
                lowerToRhs (state, env, lowerPTypes, doPSetNew, dest, oper)
              | M.RhsPSetGet v =>
                lowerToRhs (state, env, lowerPTypes, doPSetGet, dest, v)
              | M.RhsPSetCond {bool, ofVal} =>
                if lowerPTypes then
                  SOME (doPSetCond (state, env, dest, bool, ofVal))
                else
                  NONE
              (* Name small values ensures that this is never a constant *)
              | M.RhsPSetQuery (M.SVariable v) =>
                if lowerPTypes then
                  SOME (doPSetQuery (state, env, dest, v))
                else
                  NONE
              | M.RhsPSum {tag, typ, ofVal} => 
                lowerToRhs (state, env, lowerPTypes, doPSum, dest,
                            (tag, typ, ofVal))
              | M.RhsPSumProj {typ, sum, tag} =>
                lowerToRhs (state, env, lowerPTypes, doPSumProj, dest,
                            (typ, sum, tag))
              | _ => NONE
      in (env, res)
      end

  val doSwitch = 
   fn (state, env, {on, cases, default} : Mil.name Mil.switch) => 
      let
        val v = 
            case on
             of M.SVariable v => v
              | _ => fail ("doSwitch", "Arg is not a variable")
        val help = fn (nm, tg) => (M.CName nm, tg)
        val arms = Vector.map (cases, help)
        val t = M.TName
        val tgv = relatedVar (state, v, "_tag", t, false)
        val r = POM.Sum.getTag (envGetConfig env, v, M.FkRef)
        val s1 = MS.bindRhs (state, env, tgv, r)
        val tfer =
            M.TCase {on = M.SVariable tgv, cases = arms, default = default}
        val s2 = MS.transfer (state, env, tfer)
        val s = MS.seq (state, env, s1, s2)
      in (env, SOME s)
      end

  val doCall = 
   fn (state, env, mk, call, args) => 
      let
        val res = 
            case call
             of M.CCode f => NONE
              | M.CDirectClosure {cls, code} =>
                let
                  val c = envGetConfig env
                  val t = mk (POM.Function.doCall (c, code, cls, args))
                  val s = MS.transfer (state, env, t)
                in SOME s
                end
              | M.CClosure {cls, code} => 
                let
                  val c = envGetConfig env
                  val si = stateGetSymbolInfo state
                  val (aTyps, rTyps) = 
                      case MTT.variable (c, si, cls)
                       of M.TPFunction {args, ress} => (args, ress)
                        | _ => (Vector.new1 M.TPAny, Vector.new1 M.TPAny)
                  val clst = doTyp (state, env,
                                    M.TPFunction {args = aTyps, ress = rTyps})
                  val aTyps = doTyps (state, env, aTyps)
                  val rTyps = doTyps (state, env, rTyps)
                  val t = POM.Function.codeTyp (clst, aTyps, rTyps)
                  val f = relatedVar (state, cls, "_code", t, false)
                  val r = POM.Function.getCode (c, cls)
                  val s1 = MS.bindRhs (state, env, f, r)
                  val tfer = mk (POM.Function.doCall (c, f, cls, args))
                  val s2 = MS.transfer (state, env, tfer)
                  val s = MS.seq (state, env, s1, s2)
                in SOME s
                end
      in (env, res)
      end

  val transfer = 
   fn (state, env, t) =>
      let
        val res = 
            (case t
              of M.TInterProc {callee = M.IpCall {call, args}, ret, fx} =>
                 if lowerPFunctions then
                   let
                     fun mk (call, args) =
                         let
                           val c = M.IpCall {call = call, args = args}
                           val t =
                               M.TInterProc {callee = c, ret = ret, fx = fx}
                         in t
                         end
                   in
                     doCall (state, env, mk, call, args)
                   end
                 else
                   (env, NONE)
               | M.TPSumCase sw => 
                 if lowerPSums then 
                   doSwitch (state, env, sw)
                 else 
                   (env, NONE)
               | _ => (env, NONE))
      in res
      end

  val doClosureConv = 
   fn (state, env, cls, fvs, args, M.CB {entry, blocks}) =>
      let
        val c = envGetConfig env
        val si = stateGetSymbolInfo state
        val newEntry = nextBlock state
        val fvts = Vector.map (fvs, fn v => MTT.variable (c, si, v))
        val fks = Vector.map (fvts, fn t => MU.FieldKind.fromTyp (c, t))
        val project = 
         fn (i, v) =>
            M.I {dest = SOME v, rhs = POM.Function.getFv (c, fks, cls, i)}
        val projections = Vector.mapi (fvs, project)
        val parameters = Vector.new0 ()
        val transfer = M.TGoto (M.T {block = entry, arguments = Vector.new0()})
        val block =
            M.B {parameters = parameters,
                 instructions = projections,
                 transfer = transfer}
        val blocks = LD.insert (blocks, newEntry, block)
        val body = M.CB {entry = newEntry, blocks = blocks}
        val args = Utils.Vector.cons (cls, args)
      in (M.CcCode, args, body)
      end

  val doConv = 
   fn (state, env, conv, args, body) =>
      let
        val res = 
            case conv 
             of M.CcCode => (conv, args, body)
              | M.CcClosure {cls, fvs} => 
                if lowerPFunctions then 
                  doClosureConv (state, env, cls, fvs, args, body)
                else
                  (conv, args, body)
              | M.CcThunk _ => (conv, args, body)
      in res
      end

  val doCode = 
   fn (state, env, f) =>
      let
        val M.F {fx, escapes, recursive, cc, args, rtyps, body} = f
        val (conv, args, body) = doConv (state, env, cc, args, body)
        val rtyps = doTyps (state, env, rtyps)
      in
        M.F {fx = fx,
             escapes = escapes, 
             recursive = recursive,
             cc = conv,
             args = args,
             rtyps = rtyps,
             body = body}
      end

  val global = 
   fn (state, env, (v, g)) =>
      let
        val c = envGetConfig env
        val go = 
            case g
             of M.GCode code => 
                SOME (v, M.GCode (doCode (state, env, code)))
              | M.GErrorVal t => SOME (v, M.GErrorVal (doTyp (state, env, t)))
              (* name small values ensures this form *)
              | M.GSimple (M.SConstant (M.COptionSetEmpty)) => 
                if lowerPTypes then
                  SOME (v, POM.OptionSet.emptyGlobal c)
                else
                  NONE
              (* name small values ensures this form *)
              | M.GSimple (M.SConstant (M.CTypePH)) => 
                if lowerPTypes then
                  SOME (v, POM.Type.placeHolderGlobal)
                else
                  NONE
              | M.GSimple _ => NONE
              | M.GPFunction vo => 
                if lowerPFunctions then
                  let
                    val code = 
                        case vo
                         of SOME v => M.SVariable v
                          | NONE => M.SConstant (MU.UIntp.zero c)
                    val g = POM.Function.mkGlobal (c, code)
                  in SOME (v, g)
                  end
                else
                  NONE
              | M.GPSum {tag, typ, ofVal} =>
                if lowerPSums then
                  SOME (v, POM.Sum.mkGlobal (c, tag, typ, ofVal))
                else
                  NONE
              | M.GPSet s => 
                if lowerPTypes then
                  SOME (v, POM.OptionSet.mkGlobal (c, s))
                else 
                  NONE
              | M.GIdx _ => NONE
              | M.GTuple _ => NONE
              | M.GRat _ => NONE
              | M.GInteger _ => NONE
              | M.GThunkValue _ => NONE

        val gol = Option.map (go, fn (v, g) => [(v, g)])
      in (env, gol)
      end

  structure MT = MilTransformF(type state = state
                               type env = env
                               structure MSS = MSS
                               val config = envGetConfig
                               val label = label
                               val instr = instr
                               val transfer = transfer
                               val global = global
                               val indent = 2)

  val nameSmall = 
   fn (config, p) => 
      let
        val operandsToName = 
         fn oper => 
            case oper
             of M.SConstant c => 
                (case c
                  of M.COptionSetEmpty => true
                   | M.CTypePH => true
                   | _ => false)
              | M.SVariable _ => false
        val p = MilNameSmallValues.program (config, operandsToName, p)
      in p
      end

  fun doSymbolTable (state, env, stm) =
      let
        val vs = IM.variablesList stm
        fun doOne v =
            let
              val M.VI {typ, global} = MSTM.variableInfo (stm, v)
              val typ = doTyp (state, env, typ)
              val () = MSTM.variableSetInfo (stm, v, typ, global)
            in ()
            end
        val () = List.foreach (vs, doOne)
      in ()
      end

  val program = 
   fn (p, pd) => 
      let 
        val config = PassData.getConfig pd
        val p = nameSmall (config, p)
        val M.P {symbolTable = st, ...} = p
        val stm = IM.fromExistingAll st
        val state = S {stm = stm}
        val env = E {config = config}
        val p = MT.program (state, env, MT.OAny, p)
        (* Do this after transforming the program as parts of it use the
         * unlowered types of variables.
         *)
        val () = doSymbolTable (state, env, stm)
        val M.P {symbolTable, globals, entry} = p
        val st = IM.finish stm
        val p = M.P {symbolTable = st, globals = globals, entry = entry}
      in p
      end

  val description = {name        = passname,
                     description = "Lower Mil to Core Mil: " ^ desc,
                     inIr        = BothMil.irHelpers,
                     outIr       = BothMil.irHelpers,
                     mustBeAfter = [],
                     stats       = []}

  val associates = {controls  = [], debugs = [], features = [], subPasses = []}

  val pass =
      Pass.mkCompulsoryPass (description, associates,
                             BothMil.mkMilPass program) 

end

structure MilLowerPFunctions =
MilToCoreMilF(
val passname = "MilLowerPFunctions"
val desc = "P functions"
val lowerPTypes = false
val lowerPSums = false
val lowerPFunctions = true
val lowerPRefs = false)

structure MilLowerPSums = 
MilToCoreMilF(
val passname = "MilLowerPSums"
val desc = "P sums"
val lowerPTypes = false
val lowerPSums = true
val lowerPFunctions = false
val lowerPRefs = false)

structure MilLowerPTypes = 
MilToCoreMilF(
val passname = "MilLowerPTypes"
val desc = "P option sets & intensional types"
val lowerPTypes = true
val lowerPSums = false
val lowerPFunctions = false
val lowerPRefs = false)