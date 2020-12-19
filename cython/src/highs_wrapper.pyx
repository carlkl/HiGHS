# distutils: language=c++
# cython: language_level=3

from scipy.optimize import OptimizeWarning
from warnings import warn
import numbers

from libc.math cimport floor
from libc.stdio cimport stdout
from libcpp.string cimport string
from libcpp.memory cimport unique_ptr
from libcpp.map cimport map as cppmap
from libcpp.vector cimport vector

from HighsIO cimport (
    ML_NONE,
)
from HConst cimport (
    PrimalDualStatusSTATUS_FEASIBLE_POINT,
    HighsOptionTypeBOOL,
    HighsOptionTypeINT,
    HighsOptionTypeDOUBLE,
    HighsOptionTypeSTRING,
    HighsModelStatus,
    HighsModelStatusNOTSET,
    HighsModelStatusLOAD_ERROR,
    HighsModelStatusMODEL_ERROR,
    HighsModelStatusMODEL_EMPTY,
    HighsModelStatusPRESOLVE_ERROR,
    HighsModelStatusSOLVE_ERROR,
    HighsModelStatusPOSTSOLVE_ERROR,
    HighsModelStatusPRIMAL_INFEASIBLE,
    HighsModelStatusPRIMAL_UNBOUNDED,
    HighsModelStatusOPTIMAL,
    HighsModelStatusREACHED_DUAL_OBJECTIVE_VALUE_UPPER_BOUND,
    HighsModelStatusREACHED_TIME_LIMIT,
    HighsModelStatusREACHED_ITERATION_LIMIT,

    HighsVarType,
    HighsVarTypeCONTINUOUS,
    HighsVarTypeINTEGER,
)
from Highs cimport Highs
from HighsStatus cimport (
    HighsStatus,
    HighsStatusError,
    HighsStatusWarning,
    HighsStatusOK,
)
from HighsLp cimport (
    HighsLp,
    HighsSolution,

)
from HighsInfo cimport HighsInfo
from HighsOptions cimport (
    HighsOptions,
    OptionRecord,
    OptionRecordBool,
    OptionRecordInt,
    OptionRecordDouble,
    OptionRecordString,
)
from HighsMipSolver cimport HighsMipSolver

# options to reference for default values and bounds;
# make a map to quickly lookup
cdef HighsOptions _ref_opts
cdef cppmap[string, OptionRecord*] _ref_opt_lookup
cdef OptionRecord * _r = NULL
for _r in _ref_opts.records:
    _ref_opt_lookup[_r.name] = _r

cdef str _opt_warning(string name, val, valid_set=None):
    cdef OptionRecord * r = _ref_opt_lookup[name]

    # BOOL
    if r.type == HighsOptionTypeBOOL:
        default_value = (<OptionRecordBool*> r).default_value
        return ('Option "%s" is "%s", but only True or False is allowed. '
                'Using default: %s.' % (name.decode(), str(val), default_value))

    # INT
    if r.type == HighsOptionTypeINT:
        lower_bound = int((<OptionRecordInt*> r).lower_bound)
        upper_bound = int((<OptionRecordInt*> r).upper_bound)
        default_value = int((<OptionRecordInt*> r).default_value)
        if upper_bound - lower_bound < 10:
            int_range = str(set(range(lower_bound, upper_bound + 1)))
        else:
            int_range = '[%d, %d]' % (lower_bound, upper_bound)
        return ('Option "%s" is "%s", but only values in %s are allowed. '
                'Using default: %d.' % (name.decode(), str(val), int_range, default_value))

    # DOUBLE
    if r.type == HighsOptionTypeDOUBLE:
        lower_bound = (<OptionRecordDouble*> r).lower_bound
        upper_bound = (<OptionRecordDouble*> r).upper_bound
        default_value = (<OptionRecordDouble*> r).default_value
        return ('Option "%s" is "%s", but only values in (%g, %g) are allowed. '
                'Using default: %g.' % (name.decode(), str(val), lower_bound, upper_bound, default_value))

    # STRING
    if r.type == HighsOptionTypeSTRING:
        if valid_set is not None:
            descr = 'but only values in %s are allowed. ' % str(set(valid_set))
        else:
            descr = 'but this is an invalid value. %s. ' % r.description.decode()
        default_value = (<OptionRecordString*> r).default_value.decode()
        return ('Option "%s" is "%s", '
                '%s'
                'Using default: %s.' % (name.decode(), str(val), descr, default_value))

    # We don't know what type (should be unreachable)?
    return('Option "%s" is "%s", but this is not a valid value. '
           'See documentation for valid options. '
           'Using default.' % (name.decode(), str(val)))

cdef apply_options(dict options, Highs & highs):
    '''Take options from dictionary and apply to HiGHS object.'''

    # Send logging to dummy file to get rid of output from stdout
    if options.get('message_level', None) == <int> ML_NONE:
        highs.setHighsLogfile(NULL)
        highs.setHighsOutput(NULL)
    else:
        # Empty file to send to stdout
        highs.setHighsLogfile(stdout)
        highs.setHighsOutput(stdout)

    # Initialize for error checking
    cdef HighsStatus opt_status = HighsStatusOK

    # Do all the ints
    for opt in set([
            'allowed_simplex_cost_scale_factor',
            'allowed_simplex_matrix_scale_factor',
            'dual_simplex_cleanup_strategy',
            'ipm_iteration_limit',
            'keep_n_rows',
            'max_threads',
            'message_level',
            'min_threads',
            'mip_max_nodes',
            'mip_max_leaves',
            'mip_report_level',
            'simplex_crash_strategy',
            'simplex_dual_edge_weight_strategy',
            'simplex_dualise_strategy',
            'simplex_iteration_limit',
            'simplex_permute_strategy',
            'simplex_price_strategy',
            'simplex_primal_edge_weight_strategy',
            'simplex_scale_strategy',
            'simplex_strategy',
            'simplex_update_limit',
            'small_matrix_value',
    ]):
        val = options.get(opt, None)
        if val is not None:
            if not isinstance(val, int):
                warn(_opt_warning(opt.encode(), val), OptimizeWarning)
            else:
                opt_status = highs.setHighsOptionValueInt(opt.encode(), val)
                if opt_status != HighsStatusOK:
                    warn(_opt_warning(opt.encode(), val), OptimizeWarning)

    # Do all the doubles
    for opt in set([
            'dual_feasibility_tolerance',
            'dual_objective_value_upper_bound',
            'dual_simplex_cost_perturbation_multiplier',
            'dual_steepest_edge_weight_log_error_threshhold',
            'infinite_bound',
            'infinite_cost',
            'ipm_optimality_tolerance',
            'large_matrix_value',
            'mip_epsilon',
            'mip_heuristic_effort',
            'mip_optimality_tolerance',
            'primal_feasibility_tolerance',
            'simplex_initial_condition_tolerance',
            'small_matrix_value',
            'start_crossover_tolerance',
            'time_limit'
    ]):
        val = options.get(opt, None)
        if val is not None:
            if not isinstance(val, numbers.Number):
                warn(_opt_warning(opt.encode(), val), OptimizeWarning)
            else:
                opt_status = highs.setHighsOptionValueDbl(opt.encode(), val)
                if opt_status != HighsStatusOK:
                    warn(_opt_warning(opt.encode(), val), OptimizeWarning)

    # Do all the strings
    for opt in set(['solver']):
        val = options.get(opt, None)
        if val is not None:
            if not isinstance(val, str):
                warn(_opt_warning(opt.encode(), val), OptimizeWarning)
            else:
                opt_status = highs.setHighsOptionValueStr(opt.encode(), val.encode())
                if opt_status != HighsStatusOK:
                    warn(_opt_warning(opt.encode(), val), OptimizeWarning)


    # Do all the bool to strings
    for opt in set([
            'parallel',
            'presolve',
    ]):
        val = options.get(opt, None)
        if val is not None:
            if isinstance(val, bool):
                if val:
                    val0 = b'on'
                else:
                    val0 = b'off'
                opt_status = highs.setHighsOptionValueStr(opt.encode(), val0)
                if opt_status != HighsStatusOK:
                    warn(_opt_warning(opt.encode(), val, valid_set=[True, False]), OptimizeWarning)
            else:
                warn(_opt_warning(opt.encode(), val, valid_set=[True, False]), OptimizeWarning)


    # Do the actual bools
    for opt in set([
            'less_infeasible_DSE_check',
            'less_infeasible_DSE_choose_row',
            'mps_parser_type_free',
            'run_as_hsol',
            'run_crossover',
            'simplex_initial_condition_check',
            'use_original_HFactor_logic',
    ]):
        val = options.get(opt, None)
        if val is not None:
            if val in [True, False]:
                opt_status = highs.setHighsOptionValueBool(opt.encode(), val)
                if opt_status != HighsStatusOK:
                    warn(_opt_warning(opt.encode(), val), OptimizeWarning)
            else:
                warn(_opt_warning(opt.encode(), val), OptimizeWarning)


cdef dict callLpSolver(dict options, const HighsLp& lp):
    # Create the options
    cdef Highs highs
    apply_options(options, highs)
    highs.passModel(lp)
    highs.setBasis()
    cdef HighsStatus run_status = highs.run()

    # Extract what we need from the solution
    cdef HighsModelStatus model_status = highs.getModelStatus()
    cdef HighsModelStatus scaled_model_status = highs.getModelStatus(True)
    if model_status != scaled_model_status:
        if scaled_model_status == HighsModelStatusOPTIMAL:
            # The scaled model has been solved to optimality, but not the
            # unscaled model, flag this up, but report the scaled model
            # status
            warn('model_status is not optimal, using scaled_model_status instead.', OptimizeWarning)
            model_status = scaled_model_status

    # We might need an info object if we can look up the solution and a place to put solution
    cdef HighsInfo info = highs.getHighsInfo() # it should always be safe to get the info object
    cdef HighsSolution solution

    # If the status is bad, don't look up the solution
    if info.primal_status != PrimalDualStatusSTATUS_FEASIBLE_POINT:
        return {
            'status': <int> model_status,
            'message': highs.highsModelStatusToString(model_status).decode(),
            'simplex_nit': info.simplex_iteration_count,
            'ipm_nit': info.ipm_iteration_count,
            #'fun': info.objective_function_value,
            'fun': None,
            'crossover_nit': info.crossover_iteration_count,
        }
    # If the model status is such that the solution can be read
    else:
        # Should be safe to read the solution:
        solution = highs.getSolution()
        return {
            'status': <int> model_status,
            'message': highs.highsModelStatusToString(model_status).decode(),

            # Primal solution
            'x': [solution.col_value[ii] for ii in range(lp.numCol_)],

            # Ax + s = b => Ax = b - s
            # Note: this is for all constraints (A_ub and A_eq)
            'slack': [lp.rowUpper_[ii] - solution.row_value[ii] for ii in range(lp.numRow_)],

            # slacks in HiGHS appear as Ax - s, not Ax + s, so lambda is negated;
            # lambda are the lagrange multipliers associated with Ax=b
            'lambda': [-1*solution.row_dual[ii] for ii in range(lp.numRow_)],

            # s are the lagrange multipliers associated with bound conditions
            's': [solution.col_dual[ii] for ii in range(lp.numCol_) if solution.col_dual[ii]],

            'fun': info.objective_function_value,
            'simplex_nit': info.simplex_iteration_count,
            'ipm_nit': info.ipm_iteration_count,
            'crossover_nit': info.crossover_iteration_count,
        }



cdef dict callMipSolver(dict options, const HighsLp& lp):
    cdef Highs highs
    apply_options(options, highs)
    cdef unique_ptr[HighsMipSolver] solver = unique_ptr[HighsMipSolver](new HighsMipSolver(highs.getHighsOptions(), lp))
    solver.get().run()
    cdef const HighsSolution* solution = &(solver.get().presolve_.data_.recovered_solution_)
    cdef double obj
    cdef double boundviol = 0
    cdef double intviol = 0
    cdef double rowviol = 0
    cdef double mip_feasibility_tol = solver.get().options_mip_.mip_feasibility_tolerance
    cdef int ii
    if int(solution.col_value.size()) == lp.numCol_:
        print('found solution')
        obj = lp.offset_

        for ii in range(lp.numCol_):
            obj += lp.colCost_[ii]*solution.col_value[ii]
            boundviol = max(boundviol, lp.colLower_[ii] - solution.col_value[ii])
            boundviol = max(boundviol, solution.col_value[ii] - lp.colUpper_[ii])
            if lp.integrality_[ii] == HighsVarTypeINTEGER:
                intviol = max(abs(floor(solution.col_value[ii] + 0.5) - solution.col_value[ii]), intviol)

        for ii in range(lp.numRow_):
            rowviol = max(rowviol, lp.rowLower_[ii] - solution.row_value[ii])
            rowviol = max(rowviol, solution.row_value[ii] - lp.rowUpper_[ii])

        feasible = ((boundviol <= mip_feasibility_tol) and
                    (intviol <= mip_feasibility_tol) and
                    (rowviol <= mip_feasibility_tol))

        return {
            'x': [solution.col_value[ii] for ii in range(lp.numCol_)],
            'fun': obj,
            'feasible': feasible,
        }
    return {
        'fun': None,
    }

def highs_wrapper(
        double[::1] c,
        int[::1] astart,
        int[::1] aindex,
        double[::1] avalue,
        double[::1] lhs,
        double[::1] rhs,
        double[::1] lb,
        double[::1] ub,
        int[::1] intcon,
        dict options):
    '''Solve linear programs using HiGHS [1]_.

    Assume problems of the form:

        MIN c.T @ x
        s.t. lhs <= A @ x <= rhs
             lb <= x <= ub

    Parameters
    ----------
    c : 1-D array, (n,)
        Array of objective value coefficients.
    astart : 1-D array
        CSC format index array.
    aindex : 1-D array
        CSC format index array.
    avalue : 1-D array
        Data array of the matrix.
    lhs : 1-D array (or None), (m,)
        Array of left hand side values of the inequality constraints.
        If ``lhs=None``, then an array of ``-inf`` is assumed.
    rhs : 1-D array, (m,)
        Array of right hand side values of the inequality constraints.
    lb : 1-D array (or None), (n,)
        Lower bounds on solution variables x.  If ``lb=None``, then an
        array of all `0` is assumed.
    ub : 1-D array (or None), (n,)
        Upper bounds on solution variables x.  If ``ub=None``, then an
        array of ``inf`` is assumed.
    intcon : 1-D array, (k,)
        Indices of integer constrained variables.  All entries are
        assumed to be > 0 and < len(c) with no duplicates.  The caller
        is expected to perform this checking.
    options : dict
        A dictionary of solver options with the following fields:

            - allowed_simplex_cost_scale_factor : int
                Undocumented advanced option.

            - allowed_simplex_matrix_scale_factor : int
                Undocumented advanced option.

            - dual_feasibility_tolerance : double
                Dual feasibility tolerance for simplex.
                ``min(dual_feasibility_tolerance,
                primal_feasibility_tolerance)`` will be used for
                ipm feasibility tolerance.

            - dual_objective_value_upper_bound : double
                Upper bound on objective value for dual simplex:
                algorithm terminates if reached

            - dual_simplex_cleanup_strategy : int
                Undocumented advanced option.

            - dual_simplex_cost_perturbation_multiplier : double
                Undocumented advanced option.

            - dual_steepest_edge_weight_log_error_threshhold : double
                Undocumented advanced option.

            - infinite_bound : double
                Limit on abs(constraint bound): values larger than
                this will be treated as infinite

            - infinite_cost : double
                Limit on cost coefficient: values larger than this
                will be treated as infinite.

            - ipm_iteration_limit : int
                Iteration limit for interior-point solver.

            - ipm_optimality_tolerance : double
                Optimality tolerance for IPM.

            - keep_n_rows : int {-1, 0, 1}
                Undocumented advanced option.

                    - ``-1``: ``KEEP_N_ROWS_DELETE_ROWS``
                    - ``0``: ``KEEP_N_ROWS_DELETE_ENTRIES``
                    - ``1``: ``KEEP_N_ROWS_KEEP_ROWS``

            - large_matrix_value : double
                Upper limit on abs(matrix entries): values larger than
                this will be treated as infinite

            - less_infeasible_DSE_check : bool
                Undocumented advanced option.

            - less_infeasible_DSE_choose_row : bool
                Undocumented advanced option.

            - max_threads : int
                Maximum number of threads in parallel execution.

            - message_level : int {0, 1, 2, 4, 7}
                Verbosity level, corresponds to:

                    - ``0``: ``ML_NONE``
                        All messaging to stdout is supressed.

                    - ``1``: ``ML_VERBOSE``
                        Includes a once-per-iteration report on simplex/ipm
                        progress and information about each nonzero row and
                        column.

                    - ``2``: ``ML_DETAILED``
                        Includes technical information about progress and
                        events in applying the simplex method.

                    - ``4``: ``ML_MINIMAL``
                        Once-per-solve information about progress as well as a
                        once-per-basis-matrix-reinversion report on progress in
                        simplex or a once-per-iteration report on progress in IPX.

                ``message_level`` behaves like a bitmask, i.e., any
                combination of levels is possible using the bit-or
                operator.

            - min_threads : int
                Minimum number of threads in parallel execution.

            - mip_max_nodes : int
                MIP solver max number of nodes.  Must be between 0 and
                ``HIGHS_CONST_I_INF``, default is ``HIGHS_CONST_I_INF``.

            - mip_max_leaves : int
                MIP solver max number of leave nodes. Must be between 0
                and ``HIGHS_CONST_I_INF``, default is ``HIGHS_CONST_I_INF``.

            - mip_report_level : {0, 1, 2}
                MIP solver reporting level. Default is 1.

            - mip_feasibility_tolerance : double
                MIP feasibility tolerance. Must be between 1e-10 and
                ``HIGHS_CONST_INF``, default is 1e-6.

            - mip_epsilon : double
                MIP epsilon tolerance. Must be between 1e-15 and
                ``HIGHS_CONST_INF``, default is 1e-9.

            - mip_heuristic_effort : double
                Effort spent for MIP heuristics. Must be between 0.0 and
                1.0, default is 0.05.

            - mps_parser_type_free : bool
                Use free format MPS parsing.

            - parallel : bool
                Run the solver in serial (False) or parallel (True).

            - presolve : bool
                Run the presolve or not (or if ``None``, then choose).

            - primal_feasibility_tolerance : double
                Primal feasibility tolerance.
                ``min(dual_feasibility_tolerance,
                primal_feasibility_tolerance)`` will be used for
                ipm feasibility tolerance.

            - run_as_hsol : bool
                Undocumented advanced option.

            - run_crossover : bool
                Advanced option. Toggles running the crossover routine
                for IPX.

            - sense : int {1, -1}
                ``sense=1`` corresponds to the MIN problem, ``sense=-1``
                corresponds to the MAX problem. TODO: NOT IMPLEMENTED

            - simplex_crash_strategy : int {0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
                Strategy for simplex crash: off / LTSSF / Bixby (0/1/2).
                Default is ``0``.  Corresponds to the following:

                    - ``0``: ``SIMPLEX_CRASH_STRATEGY_OFF``
                    - ``1``: ``SIMPLEX_CRASH_STRATEGY_LTSSF_K``
                    - ``2``: ``SIMPLEX_CRASH_STRATEGY_BIXBY``
                    - ``3``: ``SIMPLEX_CRASH_STRATEGY_LTSSF_PRI``
                    - ``4``: ``SIMPLEX_CRASH_STRATEGY_LTSF_K``
                    - ``5``: ``SIMPLEX_CRASH_STRATEGY_LTSF_PRI``
                    - ``6``: ``SIMPLEX_CRASH_STRATEGY_LTSF``
                    - ``7``: ``SIMPLEX_CRASH_STRATEGY_BIXBY_NO_NONZERO_COL_COSTS``
                    - ``8``: ``SIMPLEX_CRASH_STRATEGY_BASIC``
                    - ``9``: ``SIMPLE_CRASH_STRATEGY_TEST_SING``

            - simplex_dualise_strategy : int
                Undocumented advanced option.

            - simplex_dual_edge_weight_strategy : int {0, 1, 2, 3, 4}
                Strategy for simplex dual edge weights:
                Dantzig / Devex / Steepest Edge. Corresponds
                to the following:

                    - ``0``: ``SIMPLEX_DUAL_EDGE_WEIGHT_STRATEGY_DANTZIG``
                    - ``1``: ``SIMPLEX_DUAL_EDGE_WEIGHT_STRATEGY_DEVEX``
                    - ``2``: ``SIMPLEX_DUAL_EDGE_WEIGHT_STRATEGY_STEEPEST_EDGE_TO_DEVEX_SWITCH``
                    - ``3``: ``SIMPLEX_DUAL_EDGE_WEIGHT_STRATEGY_STEEPEST_EDGE``
                    - ``4``: ``SIMPLEX_DUAL_EDGE_WEIGHT_STRATEGY_STEEPEST_EDGE_UNIT_INITIAL``

            - simplex_initial_condition_check : bool
                Undocumented advanced option.

            - simplex_initial_condition_tolerance : double
                Undocumented advanced option.

            - simplex_iteration_limit : int
                Iteration limit for simplex solver.

            - simplex_permute_strategy : int
                Undocumented advanced option.

            - simplex_price_strategy : int
                Undocumented advanced option.

            - simplex_primal_edge_weight_strategy : int {0, 1}
                Strategy for simplex primal edge weights:
                Dantzig / Devex.  Corresponds to the following:

                    - ``0``: ``SIMPLEX_PRIMAL_EDGE_WEIGHT_STRATEGY_DANTZIG``
                    - ``1``: ``SIMPLEX_PRIMAL_EDGE_WEIGHT_STRATEGY_DEVEX``

            - simplex_scale_strategy : int {0, 1, 2, 3, 4, 5}
                Strategy for scaling before simplex solver:
                off / on (0/1)

                    - ``0``:  ``SIMPLEX_SCALE_STRATEGY_OFF``
                    - ``1``: ``SIMPLEX_SCALE_STRATEGY_HIGHS``
                    - ``2``: ``SIMPLEX_SCALE_STRATEGY_HIGHS_FORCED``
                    - ``3``: ``SIMPLEX_SCALE_STRATEGY_HIGHS_015``
                    - ``4``: ``SIMPLEX_SCALE_STRATEGY_HIGHS_0157``
                    - ``5``: ``SIMPLEX_SCALE_STRATEGY_HSOL``

            - simplex_strategy : int {0, 1, 2, 3, 4}
                Strategy for simplex solver. Default: 1. Corresponds
                to the following:

                    - ``0``: ``SIMPLEX_STRATEGY_MIN``
                    - ``1``: ``SIMPLEX_STRATEGY_DUAL``
                    - ``2``: ``SIMPLEX_STRATEGY_DUAL_TASKS``
                    - ``3``: ``SIMPLEX_STRATEGY_DUAL_MULTI``
                    - ``4``: ``SIMPLEX_STRATEGY_PRIMAL``

            - simplex_update_limit : int
                Limit on the number of simplex UPDATE operations.

            - small_matrix_value : double
                Lower limit on abs(matrix entries): values smaller
                than this will be treated as zero.

            - solution_file : str
                Solution file

            - solver : str {'simplex', 'ipm'}
                Choose which solver to use.  If ``solver='simplex'``
                and ``parallel=True`` then PAMI will be used.

            - start_crossover_tolerance : double
                Tolerance to be satisfied before IPM crossover will
                start.

            - time_limit : double
                Max number of seconds to run the solver for.

            - use_original_HFactor_logic : bool
                Undocumented advanced option.

            - write_solution_to_file : bool
                Write the primal and dual solution to a file

            - write_solution_pretty : bool
                Write the primal and dual solution in a pretty
                (human-readable) format

        See [2]_ for a list of all non-advanced options.

    Returns
    -------
    res : dict

        If model_status is one of OPTIMAL,
        REACHED_DUAL_OBJECTIVE_VALUE_UPPER_BOUND, REACHED_TIME_LIMIT,
        REACHED_ITERATION_LIMIT:

            - ``status`` : int
                Model status code.

            - ``message`` : str
                Message corresponding to model status code.

            - ``x`` : list
                Solution variables.

            - ``slack`` : list
                Slack variables.

            - ``lambda`` : list
                Lagrange multipliers assoicated with the constraints
                Ax = b.

            - ``s`` : list
                Lagrange multipliers associated with the constraints
                x >= 0.

            - ``fun``
                Final objective value.

            - ``simplex_nit`` : int
                Number of iterations accomplished by the simplex
                solver.

            - ``ipm_nit`` : int
                Number of iterations accomplished by the interior-
                point solver.

        If model_status is not one of the above:

            - ``status`` : int
                Model status code.

            - ``message`` : str
                Message corresponding to model status code.

    Notes
    -----
    If ``options['write_solution_to_file']`` is ``True`` but
    ``options['solution_file']`` is unset or ``''``, then the solution
    will be printed to ``stdout``.

    If any iteration limit is reached, no solution will be
    available.

    ``OptimizeWarning`` will be raised if any option value set by
    the user is found to be incorrect.

    References
    ----------
    .. [1] https://www.maths.ed.ac.uk/hall/HiGHS
    .. [2] https://www.maths.ed.ac.uk/hall/HiGHS/HighsOptions.html
    '''

    cdef int numcol = c.size
    cdef int numrow = rhs.size
    cdef int numnz = avalue.size
    cdef int numint = intcon.size

    # Fill up a HighsLp object
    cdef HighsLp lp
    lp.numCol_ = numcol
    lp.numRow_ = numrow

    lp.colCost_.resize(numcol)
    lp.colLower_.resize(numcol)
    lp.colUpper_.resize(numcol)

    lp.rowLower_.resize(numrow)
    lp.rowUpper_.resize(numrow)
    lp.Astart_.resize(numcol + 1)
    lp.Aindex_.resize(numnz)
    lp.Avalue_.resize(numnz)

    # Explicitly create pointers to pass to HiGHS C++ API;
    # do checking to make sure null memory-views are not
    # accessed (e.g., &lhs[0] raises exception when lhs is
    # empty!)
    cdef:
        double * colcost_ptr = NULL
        double * collower_ptr = NULL
        double * colupper_ptr = NULL
        double * rowlower_ptr = NULL
        double * rowupper_ptr = NULL
        int * astart_ptr = NULL
        int * aindex_ptr = NULL
        double * avalue_ptr = NULL
    if numrow > 0:
        rowlower_ptr = &lhs[0]
        rowupper_ptr = &rhs[0]
        lp.rowLower_.assign(rowlower_ptr, rowlower_ptr + numrow)
        lp.rowUpper_.assign(rowupper_ptr, rowupper_ptr + numrow)
    else:
        lp.rowLower_.empty()
        lp.rowUpper_.empty()
    if numcol > 0:
        colcost_ptr = &c[0]
        collower_ptr = &lb[0]
        colupper_ptr = &ub[0]
        lp.colCost_.assign(colcost_ptr, colcost_ptr + numcol)
        lp.colLower_.assign(collower_ptr, collower_ptr + numcol)
        lp.colUpper_.assign(colupper_ptr, colupper_ptr + numcol)
    else:
        lp.colCost_.empty()
        lp.colLower_.empty()
        lp.colUpper_.empty()
    if numnz > 0:
        astart_ptr = &astart[0]
        aindex_ptr = &aindex[0]
        avalue_ptr = &avalue[0]
        lp.Astart_.assign(astart_ptr, astart_ptr + numcol + 1)
        lp.Aindex_.assign(aindex_ptr, aindex_ptr + numnz)
        lp.Avalue_.assign(avalue_ptr, avalue_ptr + numnz)
    else:
        lp.Astart_.empty()
        lp.Aindex_.empty()
        lp.Avalue_.empty()

    # Solve the LP or MIP
    cdef is_mip = numint > 0
    cdef int idx
    if is_mip:
        lp.integrality_ = vector[HighsVarType](numcol, HighsVarTypeCONTINUOUS)
        for idx in intcon:
            lp.integrality_[idx] = HighsVarTypeINTEGER
        return callMipSolver(options, lp)
    return callLpSolver(options, lp)
