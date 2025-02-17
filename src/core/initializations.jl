function hello()
    println("hello!!!")
    println("hello jack!")
end

function initialize_qG(prm::QuasiGrad.Param; Div::Int64=1, hpc_params::Bool=false)
    # In this function, we hardcode a number of important parameters
    # and intructions related to how the qG solver will operate. 
    # It also contains all of the adam solver parameters!
    #
    # printing
    if hpc_params == true
        # turn OFF printing
        print_zms                     = false # print zms at every adam iteration?
        print_freq                    = 5     # (i.e., every how often)
        print_final_stats             = false # print stats at the end?
        print_lbfgs_iterations        = false
        print_projection_success      = false
        print_linear_pf_iterations    = false
        print_reserve_cleanup_success = false
    else
        print_zms                     = true # print zms at every adam iteration?
        print_freq                    = 5    # (i.e., every how often)
        print_final_stats             = true # print stats at the end?
        print_lbfgs_iterations        = true
        print_projection_success      = false # too much :)
        print_linear_pf_iterations    = true
        print_reserve_cleanup_success = true
    end

    # how many threads?
    # => num_threads = Sys.CPU_THREADS - 2
    num_threads = Threads.nthreads()  
    nT          = length(prm.ts.time_keys)

    # should we run (or skip) line and ac binary updates via optimization (?)
    update_acline_xfm_bins = false

    # compute sus on each adam iteration?
    compute_sus_on_each_iteration = false
    compute_sus_frequency         = 5

    # buses
    num_bus = length(prm.bus.id)

    # rounding percentages for the various divisions
    pcts_to_round_D1 = [75; 100.0]
    pcts_to_round_D2 = [25.0; 50.0; 80.0; 95.0; 100.0]
    pcts_to_round_D3 = [25.0; 50.0; 75.0; 90.0; 95.0; 99.0; 100.0]
    
    # which division are we in?
    if Div == 1
        pcts_to_round = pcts_to_round_D1
    elseif Div == 2
        pcts_to_round = pcts_to_round_D2
    elseif Div == 3
        pcts_to_round = pcts_to_round_D3
    else
        @warn "Division $(Div) not recognized. Using D1."
        pcts_to_round = pcts_to_round_D1
    end

    # so: adam 1   =>   round pcts_to_round[1]
    #     adam 2   =>   round pcts_to_round[2]
    #     adam 3   =>   round pcts_to_round[3]
    #             ....
    #     adam n   =>   round pcts_to_round[n]
    #     adam n+1 =>   no more rounding! just an LP solve.

    # adam clips anything larger than grad_max -- this is no longer used!
    grad_max  = 1e11

    # these will be set programmatically
    adam_solve_times = zeros(length(pcts_to_round))

    # write location
    #   => "local" just writes in the same folder as the input
    #   => "GO" writes "solution.json" in the cwd
    write_location = "GO" # "local"

    # penalty gradients are expensive -- only compute the gradient
    # if the constraint is violated by more than this value
    pg_tol = 1e-7

    # amount to penalize constraint violations
        # => **replaced by constraint_grad_weight**
        # => delta                    = prm.vio.p_bus
        # => **replaced by constraint_grad_weight**

    # mainly for testing
    eval_grad = true

    # amount to de-prioritize binary selection over continuous variables
    # note: we don't actually care about binary values, other than the fact
    # that they imply su and sd power values
    binary_projection_weight = 1.0 # this was 0.1 for a long time!!

    # amount to prioritize power selection over other variables
    if Div == 1
        p_on_projection_weight   = 10.0
        dev_q_projection_weight  = 5.0
        binary_projection_weight = 1.0
    else
        # turn these down a bit -- zonal reserves are key
        p_on_projection_weight   = 5.0
        dev_q_projection_weight  = 2.5
        binary_projection_weight = 0.5
    end

    # gurobi feasibility tolerance -- needs to be 1e-8 for GO!
    FeasibilityTol = 9e-9
    IntFeasTol     = 9e-9

    # mip gap for Gurobi
    mip_gap = 1/100.0

    # Gurobi time limit (projection) -- set this huge, so a projection never fails,
    # even if it is running on a slow thread
    time_lim = 10.0

    # for testing:
    scale_c_pbus_testing     = 1.0
    scale_c_qbus_testing     = 1.0
    scale_c_sflow_testing    = 1.0

    # ctg solver settings
    ctg_grad_cutoff          = -250.0 # don't take gradients of ctg violations that are smaller
                                      # (in magnitude) than this value -- not worth it!
    score_all_ctgs           = false  # this is used for testing/post-processing
    min_buses_for_krylov     = 25     # don't use Krylov if there are this many or fewer buses

    # adaptively choose the frac of ctgs to keep
    if Div == 1
        if num_bus < 1500
            max_ctg_to_keep     = min(500, length(prm.ctg.id))
            max_ctg_to_backprop = min(100, length(prm.ctg.id))
        elseif num_bus < 5000
            max_ctg_to_keep     = min(350, length(prm.ctg.id))
            max_ctg_to_backprop = min(80, length(prm.ctg.id))
        elseif num_bus < 10000
            max_ctg_to_keep     = min(250, length(prm.ctg.id))
            max_ctg_to_backprop = min(70, length(prm.ctg.id))
        else
            max_ctg_to_keep     = min(25, length(prm.ctg.id))
            max_ctg_to_backprop = min(3, length(prm.ctg.id)) # :.(....
        end
    else
        if num_bus < 1500
            max_ctg_to_keep     = min(600, length(prm.ctg.id))
            max_ctg_to_backprop = min(200, length(prm.ctg.id))
        elseif num_bus < 5000
            max_ctg_to_keep     = min(450, length(prm.ctg.id))
            max_ctg_to_backprop = min(150, length(prm.ctg.id))
        elseif num_bus < 10000
            max_ctg_to_keep     = min(350, length(prm.ctg.id))
            max_ctg_to_backprop = min(100, length(prm.ctg.id))
        else
            max_ctg_to_keep     = min(250, length(prm.ctg.id))
            max_ctg_to_backprop = min(50, length(prm.ctg.id))
        end
    end
    frac_ctg_keep       = max_ctg_to_keep/length(prm.ctg.id)
    frac_ctg_backprop   = max_ctg_to_backprop/length(prm.ctg.id)
    # this is the fraction of ctgs that are scored and differentiated
    # i.e., 100*frac_ctg_keep% of them. half are random, and half a
    # the worst case performers from the previous adam iteration.

    # more finetuned:
        # => if length(prm.ctg.id) < 250
        # =>     # just keep all!
        # =>     frac_ctg_keep = 1.0
        # => elseif length(prm.ctg.id) < 1000
        # =>     frac_ctg_keep = 0.5
        # => elseif length(prm.ctg.id) < 2000
        # =>     frac_ctg_keep = 0.25
        # => elseif length(prm.ctg.id) < 5000
        # =>     frac_ctg_keep = 0.15
        # => else
        # =>     frac_ctg_keep = 0.1
        # => end

    # cg error: set the max allowable error (no error can be larger than this)
    emax = 1e-5*sqrt(num_bus) # was: 5e-5*sqrt(num_bus)
    # more generally, emax > sqrt((Ax-b)'(Ax-b)), which grows at sqrt(n) for
    # a constant error value, so we scale given error by sqrt(n) -- seems reasonable
    #
    # ctg_max_to_score score: using sortperm of negative scores, so we score 1:X
    pcg_tol                  = emax
    max_pcg_its              = Int64(round(sqrt(num_bus)))
    grad_ctg_tol             = 1e-4  # only take the gradient of ctg violations larger than this
    base_solver              = "pcg" # "lu", "pcg" for approx
    ctg_solver               = "wmi" # "lu", "pcg", for approx, "wmi" for low rank updates
    build_ctg_full           = false # build the full contingency matrices?
    build_ctg_lowrank        = true  # build the low rank contingency elements?
                                     #  -- you don't need both ^, unless for testing
    ctg_adam_counter         = 0    # this incremenets each time we take an adam step
    ctg_solve_frequency      = 3    # i.e., how often should we solve ctgs? every "x" adam steps
    always_solve_ctg         = false # for testing, mainly
    # for setting cutoff_level = memory, from LimitedLDLFactorizations.lldl:
                                     # `memory::Int=0`: extra amount of memory to allocate for the incomplete factor `L`.
                                     # The total memory allocated is nnz(T) + n * `memory`, where
                                     # `T` is the strict lower triangle of A and `n` is the size of `A`;
    # therefore, cutoff_level / memory is self-scaling! meaning, it automatically gets multuplied by "n"
    cutoff_level                 = 10     # for preconditioner -- let's be bullish here
    build_basecase_cholesky      = true   # we use this to compute the cholesky decomp of the base case
    accuracy_sparsify_lr_updates = 1.0    # trim all (sorted) values in the lr update vectors which
                                          # contribute (less than) beyond this goal
    save_sparse_WMI_updates      = false # this turns off the sparsification, which is expensive!
    # NOTE on "accuracy_sparsify_lr_updates" -- it is only helpful when 
    #      the values of u[bit_vec] are applied to the input (y[bit_vec]),
    #      but I never got this to actually be faster, so it isn't implemented
    #      -- come back to this!

    # initialize adam parameters
    decay_adam_step         = true
    homotopy_with_cos_decay = true
    adm_step                = 0
    eps                     = 1e-8  # for numerical stability -- keep at 1e-8 (?)
    beta1                   = 0.9
    beta2                   = 0.99
    beta1_decay             = 1.0
    beta2_decay             = 1.0
    one_min_beta1           = 1.0
    one_min_beta2           = 1.0
    one_min_beta1_decay     = 1.0
    one_min_beta2_decay     = 1.0

    # ====================================================================================== #
    # ====================================================================================== #
    # choose adam step sizes (initial)
    vm_t0      = 2.5e-5
    va_t0      = 2.5e-5
    phi_t0     = 2.5e-5
    tau_t0     = 2.5e-5
    dc_t0      = 1e-2
    power_t0   = 1e-2
    reserve_t0 = 1e-2
    bin_t0     = 1e-2 # bullish!!!
    alpha_t0 = Dict(
                   :vm    => vm_t0,
                   :va     => va_t0,
                   # xfm
                   :phi    => phi_t0,
                   :tau    => tau_t0,
                   # dc
                   :dc_pfr => dc_t0,
                   :dc_qto => dc_t0,
                   :dc_qfr => dc_t0,
                   # powers
                   :dev_q  => power_t0,
                   :p_on   => power_t0,
                   # reserves
                   :p_rgu     => reserve_t0,
                   :p_rgd     => reserve_t0,
                   :p_scr     => reserve_t0,
                   :p_nsc     => reserve_t0,
                   :p_rrd_on  => reserve_t0,
                   :p_rrd_off => reserve_t0,
                   :p_rru_on  => reserve_t0,
                   :p_rru_off => reserve_t0,
                   :q_qrd     => reserve_t0,
                   :q_qru     => reserve_t0,
                   # bins
                   :u_on_xfm     => bin_t0,
                   :u_on_dev     => bin_t0,
                   :u_step_shunt => bin_t0,
                   :u_on_acline  => bin_t0)

    # choose adam step sizes (final)
    vm_tf      = 2.5e-7
    va_tf      = 2.5e-7
    phi_tf     = 2.5e-7
    tau_tf     = 2.5e-7
    dc_tf      = 1e-5 
    power_tf   = 1e-5 
    reserve_tf = 1e-5 
    bin_tf     = 1e-5 # bullish!!!
    alpha_tf = Dict(
                    :vm    => vm_tf,
                    :va     => va_tf,
                    # xfm
                    :phi    => phi_tf,
                    :tau    => tau_tf,
                    # dc
                    :dc_pfr => dc_tf,
                    :dc_qto => dc_tf,
                    :dc_qfr => dc_tf,
                    # powers
                    :dev_q  => power_tf,
                    :p_on   => power_tf,
                    # reserves
                    :p_rgu     => reserve_tf,
                    :p_rgd     => reserve_tf,
                    :p_scr     => reserve_tf,
                    :p_nsc     => reserve_tf,
                    :p_rrd_on  => reserve_tf,
                    :p_rrd_off => reserve_tf,
                    :p_rru_on  => reserve_tf,
                    :p_rru_off => reserve_tf,
                    :q_qrd     => reserve_tf,
                    :q_qru     => reserve_tf,
                    # bins
                    :u_on_xfm     => bin_tf,
                    :u_on_dev     => bin_tf,
                    :u_step_shunt => bin_tf,
                    :u_on_acline  => bin_tf)
    # ====================================================================================== #
    # ====================================================================================== #

    # ====================================================================================== #
    # ====================================================================================== #
    # choose adam step sizes for power flow (initial)
    vm_pf_t0      = 2.5e-5
    va_pf_t0      = 2.5e-5
    phi_pf_t0     = 2.5e-5
    tau_pf_t0     = 2.5e-5
    dc_pf_t0      = 1e-3
    power_pf_t0   = 1e-3
    bin_pf_t0     = 1e-3 # bullish!!!
    alpha_pf_t0 = Dict(
                   :vm     => vm_pf_t0,
                   :va     => va_pf_t0,
                   # xfm
                   :phi    => phi_pf_t0,
                   :tau    => tau_pf_t0,
                   # dc
                   :dc_pfr => dc_pf_t0,
                   :dc_qto => dc_pf_t0,
                   :dc_qfr => dc_pf_t0,
                   # powers
                   :dev_q  => power_pf_t0,
                   :p_on   => power_pf_t0/10.0, # downscale active power!!!!
                   # bins
                   :u_step_shunt => bin_pf_t0)
        
    # choose adam step sizes for power flow (final)
    vm_pf_tf    = 2.5e-7
    va_pf_tf    = 2.5e-7
    phi_pf_tf   = 2.5e-7
    tau_pf_tf   = 2.5e-7
    dc_pf_tf    = 1e-5
    power_pf_tf = 1e-5
    bin_pf_tf   = 1e-5 # bullish!!!
    alpha_pf_tf = Dict(
                    :vm     => vm_pf_tf,
                    :va     => va_pf_tf,
                    # xfm
                    :phi    => phi_pf_tf,
                    :tau    => tau_pf_tf,
                    # dc
                    :dc_pfr => dc_pf_tf,
                    :dc_qto => dc_pf_tf,
                    :dc_qfr => dc_pf_tf,
                    # powers
                    :dev_q  => power_pf_tf,
                    :p_on   => power_pf_tf/10.0, # downscale active power!!!!
                    # bins
                    :u_step_shunt => bin_pf_tf)
    # ====================================================================================== #
    # ====================================================================================== #

    # ====================================================================================== #
    # ====================================================================================== #
    # choose adam step sizes for power flow (initial)
    vm_pf_t0_FIRST    = 1e-4
    va_pf_t0_FIRST    = 1e-4
    phi_pf_t0_FIRST   = 1e-4
    tau_pf_t0_FIRST   = 1e-4
    dc_pf_t0_FIRST    = 1e-2
    power_pf_t0_FIRST = 1e-2
    bin_pf_t0_FIRST   = 1e-2 # bullish!!!
    alpha_pf_t0_FIRST = Dict(
                   :vm     => vm_pf_t0_FIRST,
                   :va     => va_pf_t0_FIRST,
                   # xfm
                   :phi    => phi_pf_t0_FIRST,
                   :tau    => tau_pf_t0_FIRST,
                   # dc
                   :dc_pfr => dc_pf_t0_FIRST,
                   :dc_qto => dc_pf_t0_FIRST,
                   :dc_qfr => dc_pf_t0_FIRST,
                   # powers
                   :dev_q  => power_pf_t0_FIRST,
                   :p_on   => power_pf_t0_FIRST/15.0, # downscale active power!!!!
                   # bins
                   :u_step_shunt => bin_pf_t0_FIRST)
        
    # choose adam step sizes for power flow (final)
    vm_pf_tf_FIRST    = 5e-6
    va_pf_tf_FIRST    = 5e-6
    phi_pf_tf_FIRST   = 5e-6
    tau_pf_tf_FIRST   = 5e-6
    dc_pf_tf_FIRST    = 2.5e-4
    power_pf_tf_FIRST = 2.5e-4
    bin_pf_tf_FIRST   = 2.5e-4 # bullish!!!
    alpha_pf_tf_FIRST = Dict(
                    :vm     => vm_pf_tf_FIRST,
                    :va     => va_pf_tf_FIRST,
                    # xfm
                    :phi    => phi_pf_tf_FIRST,
                    :tau    => tau_pf_tf_FIRST,
                    # dc
                    :dc_pfr => dc_pf_tf_FIRST,
                    :dc_qto => dc_pf_tf_FIRST,
                    :dc_qfr => dc_pf_tf_FIRST,
                    # powers
                    :dev_q  => power_pf_tf_FIRST,
                    :p_on   => power_pf_tf_FIRST/15.0, # downscale active power!!!!
                    # bins
                    :u_step_shunt => bin_pf_tf_FIRST)
    # ====================================================================================== #
    # ====================================================================================== #

    # ====================================================================================== #
    # ====================================================================================== #
    # choose adam step size (current) -- this will always be overwritten
    alpha_tnow = deepcopy(alpha_tf)

    # adam plotting
    plot_scale_up = 2.0
    plot_scale_dn = 1e8

    # adam runtime
    adam_max_time = 60.0 # only one is true -- overwritten in GO iterations
    adam_t1       = 60.0 #  -- overwritten in GO iterations
    adam_t2       = 60.0 #  -- overwritten in GO iterations
    adam_max_its  = 300  # only one is true
    adam_stopper  = "time" # "iterations"

    # gradient modifications ====================================================
    apply_grad_weight_homotopy = true
    # see the homotopy file for more parameters!!!

    # gradient modifications -- power balance
    pqbal_grad_type     = "soft_abs" # "scaled_quadratic" "quadratic_for_lbfgs", "standard"
    pqbal_grad_weight_p = prm.vio.p_bus # standard: prm.vio.p_bus
    pqbal_grad_weight_q = prm.vio.q_bus # standard: prm.vio.q_bus
    pqbal_grad_eps2     = 1e-5
    # in the following, we tune the weight so that the quadratic power balance gradients
    # match the standard gradients (in terms of magnitude) when p/q_error = 0.05 -- after
    # that point, they get weaker; before that, they get stronger
    pqbal_quadratic_grad_weight_p = 100.0*prm.vio.p_bus/(2.0*0.05)
    pqbal_quadratic_grad_weight_q = 100.0*prm.vio.q_bus/(2.0*0.05)

    # gradient modification for constraints
    constraint_grad_is_soft_abs = true # "standard"
    constraint_grad_weight = prm.vio.p_bus
    constraint_grad_eps2 = 1e-4

    # gradient modification for ac flow penalties
    acflow_grad_is_soft_abs = true
    acflow_grad_weight      = prm.vio.s_flow
    acflow_grad_eps2        = 1e-4

    # gradient modification for ctg flow penalties
    # => @warn "ctg gradient modification not yet implemented!"
    # NOTE -- we ran out of time in E3, and did NOT implement the softabs
    #         on ctg gradients -- this is probably fine -- you can easily
    #         compute it when the max() operator is applied, here:
    #           => bit.sfr_vio .= (flw.sfr_vio .> qG.grad_ctg_tol) .&& (flw.sfr_vio .> flw.sto_vio)
    #           => bit.sto_vio .= (flw.sto_vio .> qG.grad_ctg_tol) .&& (flw.sto_vio .> flw.sfr_vio)
    ctg_grad_is_soft_abs = true # "standard"
    ctg_grad_weight    = prm.vio.s_flow
    ctg_grad_eps2      = 1e-4
    ctg_memory         = 0.25                # how much memory should we give the ctg gradients?
    one_min_ctg_memory = 1.0 - ctg_memory    # ctg_memory + one_min_ctg_memory = 1 !!
    # NOTE: for no memory, just set ctg_memory = 0.0 -- then, every new gradient will be linearly 
    #       added and applied, and no smoothing will take place (except via adam itself!)

    # gradient modification for reserves (we do NOT perturb reserve gradient weights -- they are small enough!)
    reserve_grad_is_soft_abs = true # "standard"
    reserve_grad_eps2 = 1e-4

    # ===========================================================================

    # shall we compute injections when we build the Jacobian?
    compute_pf_injs_with_Jac   = true
    if Div == 1
        max_pf_dx                  = 1e-4    # stop when max delta < 5e-4
        max_pf_dx_final_solve      = 1e-5    # final pf solve
        max_linear_pfs_final_solve = 3
        max_linear_pfs             = 3       # stop when number of pfs > max_linear_pfs
    else
        max_pf_dx                  = 1e-4    # stop when max delta < 5e-4
        max_pf_dx_final_solve      = 1e-5  # final pf solve
        max_linear_pfs_final_solve = 3
        max_linear_pfs             = 3       # stop when number of pfs > max_linear_pfs
    end
    
    Gurobi_pf_obj = "l2_penalties" # "min_dispatch_distance" or, "min_dispatch_perturbation"

    # don't use given initializations
    initialize_shunt_to_given_value = false
    initialize_vm_to_given_value    = false

    # power flow solve parameters ==============================
    #
    # strength of quadratic distance regularization
    cdist_psolve = 1e5

    # turn of su/sd updates, which is expensive, during power flow solves
    run_susd_updates = true

    # bias terms of solving bfgs
    run_lbfgs                       = false # use adam instead ;)
    include_energy_costs_lbfgs      = false
    include_lbfgs_p0_regularization = false
    initial_pf_lbfgs_step           = 0.005  # keep this tiny!! a little bigger since the update..
    lbfgs_adam_alpha_0              = 0.001  # keep this tiny!!
    lbfgs_map_over_all_time         = false  # assume the same set of variables
                                             # are optimized at each time step
    # how many historical gradients do we keep? 
    # 2 < n < 21, according to Wright
    num_lbfgs_to_keep = 8

    # set the number of lbfgs steps
    num_lbfgs_steps = 250

    # when we clip p/q in bounds, should we clip based on binary values?
    # generally, only do this on the LAST adam iteration,
    clip_pq_based_on_bins = true

    # for the_quasiGrad! solver itself
    first_qG_step      = true
    first_qG_step_size = 1e-15

    # skip ctg eval?
    skip_ctg_eval = false

    # adam solving pf
    take_adam_pf_steps = false
    num_adam_pf_step   = 3
    adam_pf_variables  = [:vm, :va, :tau, :phi, :dc_pfr, :dc_qfr, :dc_qto, :u_step_shunt, :p_on, :dev_q]

    # build the mutable struct
    qG = QG(
        nT,
        num_threads,
        update_acline_xfm_bins,
        print_projection_success,
        print_reserve_cleanup_success,
        compute_sus_on_each_iteration,
        compute_sus_frequency,
        pcts_to_round,
        cdist_psolve,
        run_susd_updates,
        grad_max,
        adam_solve_times,
        write_location,
        pg_tol,
        eval_grad,
        binary_projection_weight,
        p_on_projection_weight,
        dev_q_projection_weight,
        print_final_stats,
        FeasibilityTol,
        IntFeasTol,
        mip_gap,
        time_lim,
        print_zms,
        print_freq,
        scale_c_pbus_testing,
        scale_c_qbus_testing,
        scale_c_sflow_testing,
        ctg_grad_cutoff,
        score_all_ctgs,
        min_buses_for_krylov,
        frac_ctg_keep,
        frac_ctg_backprop,
        pcg_tol,
        max_pcg_its,
        grad_ctg_tol,
        cutoff_level,
        build_basecase_cholesky,      
        accuracy_sparsify_lr_updates,
        save_sparse_WMI_updates,
        base_solver,
        ctg_solver,
        build_ctg_full,
        build_ctg_lowrank,
        ctg_adam_counter,   
        ctg_solve_frequency,
        always_solve_ctg,
        decay_adam_step,
        homotopy_with_cos_decay,
        adm_step,
        eps,
        beta1,
        beta2,
        beta1_decay,
        beta2_decay,
        one_min_beta1,
        one_min_beta2,
        one_min_beta1_decay,
        one_min_beta2_decay,
        alpha_tf,
        alpha_t0,
        alpha_pf_t0,
        alpha_pf_tf,
        alpha_pf_t0_FIRST,
        alpha_pf_tf_FIRST,
        alpha_tnow,
        plot_scale_up, 
        plot_scale_dn, 
        adam_max_time, 
        adam_t1,
        adam_t2,
        adam_max_its,
        adam_stopper,
        apply_grad_weight_homotopy,
        pqbal_grad_type,
        pqbal_grad_weight_p,
        pqbal_grad_weight_q,
        pqbal_grad_eps2,
        pqbal_quadratic_grad_weight_p,
        pqbal_quadratic_grad_weight_q,
        constraint_grad_is_soft_abs, 
        constraint_grad_weight,
        constraint_grad_eps2,
        acflow_grad_is_soft_abs,
        acflow_grad_weight,
        acflow_grad_eps2,
        ctg_grad_is_soft_abs,
        ctg_grad_weight,
        ctg_grad_eps2,
        ctg_memory,        
        one_min_ctg_memory,
        reserve_grad_is_soft_abs,
        reserve_grad_eps2,
        compute_pf_injs_with_Jac,
        max_pf_dx,
        max_pf_dx_final_solve,
        max_linear_pfs_final_solve,
        max_linear_pfs,
        print_linear_pf_iterations,
        Gurobi_pf_obj,
        initialize_shunt_to_given_value,
        initialize_vm_to_given_value,
        run_lbfgs,
        include_energy_costs_lbfgs,
        include_lbfgs_p0_regularization,
        print_lbfgs_iterations,
        initial_pf_lbfgs_step,
        lbfgs_adam_alpha_0,
        lbfgs_map_over_all_time,
        num_lbfgs_to_keep,
        num_lbfgs_steps,
        clip_pq_based_on_bins,
        first_qG_step,
        first_qG_step_size,
        skip_ctg_eval,
        take_adam_pf_steps,
        num_adam_pf_step,  
        adam_pf_variables)
    
    # output
    return qG
end

function base_initialization(jsn::Dict{String, Any}; Div::Int64=1, hpc_params::Bool = false, perturb_states::Bool=false, pert_size::Float64=1.0, line_switching::Int64=0)
    # perform all initializations from the jsn data

    # first, set the BLAS thread limit to 1, to be safe
    LinearAlgebra.BLAS.set_num_threads(1)

    # parse the input jsn data
    prm, idx, sys = parse_json(jsn)

    # build the qg structure
    qG = initialize_qG(prm, Div=Div, hpc_params=hpc_params)

    # intialize (empty) states
    cgd, grd, mgd, scr, stt = initialize_states(idx, prm, sys, qG)

    # switch lines? if so, turn them all on!
    if line_switching == 1
        prm.acline.init_on_status .= 1.0
        prm.xfm.init_on_status    .= 1.0
        for tii in prm.ts.time_keys
            stt.u_on_acline[tii] .= 1.0
            stt.u_on_xfm[tii] .= 1.0
        end
    end

    # initialize the states which adam will update -- the rest are fixed
    adm = initialize_adam_states(prm, qG, sys)

    # define the states which adam can/will update, and fix the rest!
    upd = identify_update_states(prm, idx, stt, sys)

    # initialize the contingency network structure and reusable vectors in dicts
    ctg, ntk, flw = initialize_ctg(stt, sys, prm, qG, idx)

    # initialize lbfgs
    lbf = initialize_lbfgs(mgd, prm, qG, stt, sys, upd)

    # shall we randomly perutb the states?
    if perturb_states == true
        QuasiGrad.Random.seed!(1)
        @info "applying perturbation of size $pert_size with random device binaries"
        perturb_states!(pert_size, prm, stt, sys)

        # re-call the update function -- this must always
        # be called after a random perturbation!
        upd = identify_update_states(prm, idx, stt, sys)
    end

    # release memory and force garbage collection
    jsn = 0; GC.gc()

    # output
    return adm, cgd, ctg, flw, grd, idx, lbf, mgd, ntk, prm, qG, scr, stt, sys, upd
end

function initialize_indices(prm::QuasiGrad.Param, sys::QuasiGrad.System)
    # define the flow indices (used to update a flow vector)
    ac_line_flows    = collect(1:sys.nl)
    ac_xfm_flows     = collect((sys.nl + 1):(sys.nac))
    ac_phi           = collect((sys.nl + 1):(sys.nac))  # indices of ac devices with potential phase shift

    # Next, we define a mapping: from bus ids to indices
    # Note: "Int64" is safe, unless there is an id we are looking for which
    # is not inside of "prm.bus.id)", but this should never be the case
    acline_fr_bus = Int64.(indexin(prm.acline.fr_bus,prm.bus.id))
    acline_to_bus = Int64.(indexin(prm.acline.to_bus,prm.bus.id))
    xfm_fr_bus    = Int64.(indexin(prm.xfm.fr_bus,prm.bus.id))
    xfm_to_bus    = Int64.(indexin(prm.xfm.to_bus,prm.bus.id))
    ac_fr_bus     = [acline_fr_bus; xfm_fr_bus] # acline + xfm
    ac_to_bus     = [acline_to_bus; xfm_to_bus] # acline + xfm
    dc_fr_bus     = Int64.(indexin(prm.dc.fr_bus,prm.bus.id))
    dc_to_bus     = Int64.(indexin(prm.dc.to_bus,prm.bus.id))
    shunt_bus     = Int64.(indexin(prm.shunt.bus,prm.bus.id))

    # create a dictionary which maps buses to the lines/xfms/dc lines,
    # where this bus is a "fr" bus or a "to" bus
    bus_is_acline_frs = Dict(name => Vector{Int64}() for name in 1:sys.nb)
    bus_is_acline_tos = Dict(name => Vector{Int64}() for name in 1:sys.nb)
    bus_is_xfm_frs    = Dict(name => Vector{Int64}() for name in 1:sys.nb)
    bus_is_xfm_tos    = Dict(name => Vector{Int64}() for name in 1:sys.nb)
    bus_is_dc_frs     = Dict(name => Vector{Int64}() for name in 1:sys.nb)
    bus_is_dc_tos     = Dict(name => Vector{Int64}() for name in 1:sys.nb)

    # loop and populate! acline
    for bus = 1:sys.nb
        # acline
        bus_is_acline_frs[bus] = findall(x -> x .== bus, acline_fr_bus)
        bus_is_acline_tos[bus] = findall(x -> x .== bus, acline_to_bus)

        # xfm
        bus_is_xfm_frs[bus] = findall(x -> x .== bus, xfm_fr_bus)
        bus_is_xfm_tos[bus] = findall(x -> x .== bus, xfm_to_bus)

        # dc line
        bus_is_dc_frs[bus] = findall(x -> x .== bus, dc_fr_bus)
        bus_is_dc_tos[bus] = findall(x -> x .== bus, dc_to_bus)
    end

    # split into producers and consumers
    pr_inds = findall(x -> x == "producer", prm.dev.device_type)
    cs_inds = findall(x -> x == "consumer", prm.dev.device_type)

    # pr and cs and shunt device mappings
    bus_to_pr          = Dict(ii => Int64[] for ii in 1:(sys.nb))
    bus_to_cs          = Dict(ii => Int64[] for ii in 1:(sys.nb))
    bus_to_sh          = Dict(ii => Int64[] for ii in 1:(sys.nb))
    bus_to_pr_not_Jpqe = Dict(ii => Int64[] for ii in 1:(sys.nb))
    bus_to_cs_not_Jpqe = Dict(ii => Int64[] for ii in 1:(sys.nb))
    bus_to_pr_and_Jpqe = Dict(ii => Int64[] for ii in 1:(sys.nb))
    bus_to_cs_and_Jpqe = Dict(ii => Int64[] for ii in 1:(sys.nb))

    # we are also going to append the devices associated with a given bus
    # into their corresponding zones -- slow, but necessary
    pr_pzone  = Dict(ii => Int64[] for ii in 1:(sys.nzP))
    cs_pzone  = Dict(ii => Int64[] for ii in 1:(sys.nzP))
    dev_pzone = Dict(ii => Int64[] for ii in 1:(sys.nzP))

    pr_qzone  = Dict(ii => Int64[] for ii in 1:(sys.nzQ))
    cs_qzone  = Dict(ii => Int64[] for ii in 1:(sys.nzQ))
    dev_qzone = Dict(ii => Int64[] for ii in 1:(sys.nzQ))

    # 1:1 mapping, from device number, to its bus
    device_to_bus = zeros(Int64, sys.ndev)

    for bus = 1:sys.nb
        # get the devices tied to this bus
        bus_id             = prm.bus.id[bus]
        dev_on_bus_inds    = findall(x -> x == bus_id, prm.dev.bus)
        sh_dev_on_bus_inds = findall(x -> x == bus_id, prm.shunt.bus)

        # broadcast
        device_to_bus[dev_on_bus_inds] .= bus

        # are the devices consumers or producers?
        pr_devs_on_bus = dev_on_bus_inds[in.(dev_on_bus_inds,Ref(pr_inds))]
        cs_devs_on_bus = dev_on_bus_inds[in.(dev_on_bus_inds,Ref(cs_inds))]

        # update dictionaries
        bus_to_pr[bus] = pr_devs_on_bus
        bus_to_cs[bus] = cs_devs_on_bus
        bus_to_sh[bus] = sh_dev_on_bus_inds

        # filter out the devs in Jpqe
        bus_to_pr_not_Jpqe[bus] = setdiff(pr_devs_on_bus, prm.dev.J_pqe)
        bus_to_cs_not_Jpqe[bus] = setdiff(cs_devs_on_bus, prm.dev.J_pqe)

        # keep just the devs in Jpqe
        bus_to_pr_and_Jpqe[bus] = intersect(pr_devs_on_bus, prm.dev.J_pqe)
        bus_to_cs_and_Jpqe[bus] = intersect(cs_devs_on_bus, prm.dev.J_pqe)

        # first, the active power zones
        for pzone_id in prm.bus.active_rsvid[bus]
            # grab the zone index
            pz_ind = findfirst(x -> x == pzone_id, prm.reserve.id_pzone)

            # push the pr and cs devices into a list
            append!(pr_pzone[pz_ind], pr_devs_on_bus)
            append!(cs_pzone[pz_ind], cs_devs_on_bus)
            append!(dev_pzone[pz_ind], pr_devs_on_bus, cs_devs_on_bus)
        end

        # second, the REactive power zones
        for qzone_id in prm.bus.reactive_rsvid[bus]
            # grab the zone index
            qz_ind = findfirst(x -> x == qzone_id, prm.reserve.id_qzone)

            # push the pr and cs devices into a list
            append!(pr_qzone[qz_ind], pr_devs_on_bus)
            append!(cs_qzone[qz_ind], cs_devs_on_bus)
            append!(dev_qzone[qz_ind], pr_devs_on_bus, cs_devs_on_bus)
        end
    end

    # let's also get the set of pr/cs not in pqe (without equality linking)
    pr_and_Jpqe = intersect(pr_inds, prm.dev.J_pqe)
    cs_and_Jpqe = intersect(cs_inds, prm.dev.J_pqe)
    pr_not_Jpqe = setdiff(pr_inds,   prm.dev.J_pqe)
    cs_not_Jpqe = setdiff(cs_inds,   prm.dev.J_pqe)

    # build the various timing sets (Ts) needed by devices -- this is quite
    # a bit of data to store, but regenerating it each time is way too slow
    Ts_mndn, Ts_mnup, Ts_sdpc, ps_sdpc_set, Ts_supc,
    ps_supc_set, Ts_sus_jft, Ts_sus_jf, Ts_en_max, 
    Ts_en_min, Ts_su_max = build_time_sets(prm, sys)

    # combine
    idx = Index(
        acline_fr_bus,
        acline_to_bus,
        xfm_fr_bus,
        xfm_to_bus,
        ac_fr_bus,
        ac_to_bus,
        dc_fr_bus,
        dc_to_bus,
        ac_line_flows,        # index of acline flows in a vector of all lines
        ac_xfm_flows,         # index of xfm flows in a vector of all line flows
        ac_phi,               # index of xfm shifts in a vector of all lines
        bus_is_acline_frs,
        bus_is_acline_tos,
        bus_is_xfm_frs,
        bus_is_xfm_tos,
        bus_is_dc_frs,
        bus_is_dc_tos,
        prm.dev.J_pqe,
        prm.dev.J_pqmax,       # NOTE: J_pqmax == J_pqmin :)
        prm.dev.J_pqmax,       # NOTE: J_pqmax == J_pqmin :)
        prm.xfm.J_fpd,
        prm.xfm.J_fwr,
        bus_to_pr,             # maps a bus number to the pr's on that bus
        bus_to_cs,             # maps a bus number to the cs's on that bus
        bus_to_sh,             # maps a bus number to the sh's on that bus
        bus_to_pr_not_Jpqe,    # maps a bus number to the pr's on that bus (not in Jpqe)
        bus_to_cs_not_Jpqe,    # maps a bus number to the cs's on that bus (not in Jpqe)
        bus_to_pr_and_Jpqe,    # maps a bus number to the pr's on that bus (also in Jpqe)
        bus_to_cs_and_Jpqe,    # maps a bus number to the cs's on that bus (also in Jpqe)
        shunt_bus,             # simple list of buses for shunt devices
        pr_inds,               # simple list of producer inds
        cs_inds,               # simple list of consumer inds
        pr_and_Jpqe,           # prs that have equality links on Q
        cs_and_Jpqe,           # css that have equality links on Q
        pr_not_Jpqe,           # prs that DO NOT have equality links on Q
        cs_not_Jpqe,           # css that DO NOT have equality links on Q
        device_to_bus,         # device index => bus index
        pr_pzone,              # maps a pzone number to the list of producers in that zone
        cs_pzone,              # maps a pzone number to the list of consumers in that zone
        dev_pzone,             # maps a pzone number to the list of devices in that zone
        pr_qzone,              # maps a qzone number to the list of producers in that zone
        cs_qzone,              # maps a qzone number to the list of consumers in that zone
        dev_qzone,             # maps a qzone number to the list of devices in that zone
        Ts_mndn,               # time sets!!
        Ts_mnup, 
        Ts_sdpc, 
        ps_sdpc_set, 
        Ts_supc, 
        ps_supc_set, 
        Ts_sus_jft, 
        Ts_sus_jf, 
        Ts_en_max, 
        Ts_en_min, 
        Ts_su_max)

    # output
    return  idx
end

function initialize_states(idx::QuasiGrad.Index, prm::QuasiGrad.Param, sys::QuasiGrad.System, qG::QuasiGrad.QG)
    
    # build stt
    stt = build_state(prm, sys, qG)

    # build grd
    grd = build_grad(prm, sys)

    # build the (fully initialized) cgd: constant gradient structure
    cgd = build_constant_gradient(idx, prm, qG, sys)

    # mgd = master grad -- this is the gradient which relates the negative market surplus function 
    #   with all "basis" variables -- i.e., the variables for which all others are computed.
    #   These are *exactly* (I think..) the variables which are reported in the solution file
    mgd = build_master_grad(prm, sys)

    # build scr -- this is the only dictionary we use
    scr = Dict(
        :nzms            => 0.0,   # this is what we explicitly minimize
        :zms             => 0.0,   # this is what we implicitly maximize
        :zbase           => 0.0,
        :zctg_min        => 0.0,
        :zctg_avg        => 0.0,
        :zhat_mxst       => 0.0,
        :zt_original     => 0.0, # zt = zt_original + zt_penalty
        :zt_penalty      => 0.0, # zt = zt_original + zt_penalty
        :z_enmax         => 0.0,
        :z_enmin         => 0.0,
        # many extra things for score plotting -- not super well named
        :zms_penalized   => 0.0,
        :zbase_penalized => 0.0,
        :emnx            => 0.0,
        :zp              => 0.0,
        :zq              => 0.0,
        :acl             => 0.0,
        :xfm             => 0.0,
        :zoud            => 0.0,
        :zone            => 0.0,
        :rsv             => 0.0,
        :enpr            => 0.0,
        :encs            => 0.0,
        :zsus            => 0.0,
        :cnt             => 0.0,
        :ed_obj          => 0.0) # hold the ed solution

        # build an output

    # output
    return cgd, grd, mgd, scr, stt
end

function identify_update_states(prm::QuasiGrad.Param, idx::QuasiGrad.Index, stt::QuasiGrad.State, sys::QuasiGrad.System)
    # in this function, we will handle five types of fixed variables:
    #   1. must run binaries
    #   2. planned outage binaries and their powers
    #   3. variables which take a pre-defined fixed value of 0
    #   4. phase angle reference
    #   5. line/xfm binaries
        #    -> binaries which have been rounded and fixed (i.e., -- ibr)
        #       via Gurobi will handled later
    #
    # all other, non-fixed states are "variable" states
    upd   = Dict(:u_on_dev     => [collect(1:sys.ndev) for tii in prm.ts.time_keys],
                 :p_rrd_off    => [collect(1:sys.ndev) for tii in prm.ts.time_keys],
                 :p_nsc        => [collect(1:sys.ndev) for tii in prm.ts.time_keys],
                 :p_rru_off    => [collect(1:sys.ndev) for tii in prm.ts.time_keys],
                 :q_qru        => [collect(1:sys.ndev) for tii in prm.ts.time_keys],
                 :q_qrd        => [collect(1:sys.ndev) for tii in prm.ts.time_keys],
                 :phi          => [collect(1:sys.nx)   for tii in prm.ts.time_keys],
                 :tau          => [collect(1:sys.nx)   for tii in prm.ts.time_keys],
                 :dc_pto       => [collect(1:sys.nldc) for tii in prm.ts.time_keys],
                 :va           => [collect(1:sys.nb)   for tii in prm.ts.time_keys],
                 :u_on_acline  => [collect(1:sys.nl)   for tii in prm.ts.time_keys],
                 :u_on_xfm     => [collect(1:sys.nx)   for tii in prm.ts.time_keys],
                 :u_step_shunt => [collect(1:sys.nsh)  for tii in prm.ts.time_keys])

    # 1. must run sets =======================================
    for dev in reverse(1:sys.ndev)
        tmr  = get_tmr(dev, prm)
        for tii in tmr
            # set the binaries
            stt.u_on_dev[tii][dev] = 1.0

            # remove the device from the update list -- 
            # this is safe because we are looping over the
            # devices in reverse order
            deleteat!(upd[:u_on_dev][tii],dev);
        end

    # 2. planned outages =======================================
        tout = get_tout(dev, prm)
        for tii in tout
            # set the binaries
            stt.u_on_dev[tii][dev] .= 0.0
            # remove the device from the update list -- 
            # this is safe because we are looping over the
            # devices in reverse order -- furthermore, tmr and 
            # tout are mutually exclusive, so it is
            # safe to test the same device for removal from the
            # update list for must run and then outage
            deleteat!(upd[:u_on_dev][tii],dev);
        end
    end

    # 3. pre-defined fixed values =======================================
    #
    # first, we fix the values correctly
    for tii in prm.ts.time_keys
        stt.p_rrd_off[tii][idx.pr_devs] .= 0.0   # see (106)
        stt.p_nsc[tii][idx.cs_devs]     .= 0.0   # see (107)
        stt.p_rru_off[tii][idx.cs_devs] .= 0.0   # see (108)
        stt.q_qru[tii][idx.pr_and_Jpqe] .= 0.0   # see (117)
        stt.q_qrd[tii][idx.pr_and_Jpqe] .= 0.0   # see (118)
        stt.q_qru[tii][idx.cs_and_Jpqe] .= 0.0   # see (127)
        stt.q_qrd[tii][idx.cs_and_Jpqe] .= 0.0   # see (128)
        stt.phi[tii][idx.J_fpd]         .= prm.xfm.init_phi[idx.J_fpd] # see (144)
        stt.tau[tii][idx.J_fwr]         .= prm.xfm.init_tau[idx.J_fwr] # see (144)
        stt.dc_pto[tii]                 .= -stt.dc_pfr[tii]

        # remove states from the update list -- this is safe
        deleteat!(upd[:p_rrd_off][tii],idx.pr_devs)
        deleteat!(upd[:p_nsc][tii],idx.cs_devs)
        deleteat!(upd[:p_rru_off][tii],idx.cs_devs)
        deleteat!(upd[:q_qru][tii],idx.J_pqe)
        deleteat!(upd[:q_qrd][tii],idx.J_pqe)
        deleteat!(upd[:phi][tii],idx.J_fpd)
        deleteat!(upd[:tau][tii],idx.J_fwr)
        deleteat!(upd[:dc_pto][tii], collect(1:sys.nldc))
    end

    # 4. phase angle reference =======================================
    #
    # always bus #1 !!!
    for tii in prm.ts.time_keys
        stt.va[tii][1] = 0
        deleteat!(upd[:va][tii], 1)
    end

    # 5. sadly, don't switch lines this round
    for tii in prm.ts.time_keys
        upd[:u_on_acline][tii] = Int64[]
        upd[:u_on_xfm][tii]    = Int64[]
    end

    # output
    return upd
end

function build_sys(json_data::Dict{String, Any})
    nb    = length(json_data["network"]["bus"])
    nx    = length(json_data["network"]["two_winding_transformer"])
    nsh   = length(json_data["network"]["shunt"])
    nl    = length(json_data["network"]["ac_line"])
    nac   = nl+nx
    nldc  = length(json_data["network"]["dc_line"])
    ndev  = length(json_data["network"]["simple_dispatchable_device"])
    ncs   = sum((ii["device_type"]=="consumer") for ii in json_data["network"]["simple_dispatchable_device"])
    npr   = sum((ii["device_type"]=="producer") for ii in json_data["network"]["simple_dispatchable_device"])
    nT    = json_data["time_series_input"]["general"]["time_periods"]
    nvar  = 2*nb + 2*nx + nx + nl
    nzP   = length(json_data["network"]["active_zonal_reserve"])
    nzQ   = length(json_data["network"]["reactive_zonal_reserve"])
    nctg  = length(json_data["reliability"]["contingency"])
    sys   = System(
                    nb,
                    nx,
                    nsh,
                    nl,
                    nac,
                    nldc,
                    ndev,
                    ncs,
                    npr,
                    nT,
                    nvar,
                    nzP,
                    nzQ,
                    nctg)

    # output
    return sys
end

function join_params(ts_prm::Dict, dc_prm::Dict, ctg_prm::Dict, bus_prm::Dict, xfm_prm::Dict, vio_prm::Dict, shunt_prm::Dict, acline_prm::Dict, device_prm::Dict, reserve_prm::Dict)
    prm = Dict(
        :ts          => ts_prm,
        :dc          => dc_prm,
        :ctg         => ctg_prm,
        :bus         => bus_prm,
        :xfm         => xfm_prm,
        :vio         => vio_prm,
        :dev         => device_prm,
        :shunt       => shunt_prm,
        :acline      => acline_prm,
        :reserve     => reserve_prm)

    # output
    return prm
end

# build everything that will be needed to solve ctgs
function initialize_ctg(stt::QuasiGrad.State, sys::QuasiGrad.System, prm::QuasiGrad.Param, qG::QuasiGrad.QG, idx::QuasiGrad.Index)
    # note, the reference bus is always bus #1
    #
    # first, get the ctg limits
    s_max_ctg = [prm.acline.mva_ub_em; prm.xfm.mva_ub_em]

    # get the ordered names of all components
    ac_ids = [prm.acline.id; prm.xfm.id ]

    # get the ordered (negative!!) susceptances
    ac_b_params = -[prm.acline.b_sr; prm.xfm.b_sr]
    
    # build the full incidence matrix: E = lines x buses
    E, Efr, Eto = build_incidence(idx, prm, stt, sys)
    Er = E[:,2:end]
    ErT = copy(Er')

    # get the diagonal admittance matrix   => Ybs == "b susceptance"
    Ybs = QuasiGrad.spdiagm(ac_b_params)
    Yb  = E'*Ybs*E
    Ybr = Yb[2:end,2:end]  # use @view ? 

    # should we precondition the base case?
    #
    # Note: Ybr should be sparse!! otherwise,
    # the sparse preconditioner won't have any memory limits and
    # will be the full Chol-decomp -- not a big deal, I guess..
    #
    # time is short -- let's jsut always use ldl preconditioner -- it's just as fast
    Ybr_ChPr = QuasiGrad.Preconditioners.lldl(Ybr, memory = qG.cutoff_level);

    # warn, if too few buses
    if sys.nb <= qG.min_buses_for_krylov
        # too few buses -- use LU
        println("Not enough buses for Krylov! Using LU for all Ax=b system solves.")
    end
    
    # should we build the cholesky decomposition of the base case
    # admittance matrix? we build this to compute high-fidelity
    # solutions of the rank-1 update matrices
    if minimum(ac_b_params) < 0.0
        @info "Yb not PSd -- using ldlt (instead of cholesky) to construct WMI update vectors."
        Ybr_Ch = QuasiGrad.ldlt(Ybr)
    else
        Ybr_Ch = QuasiGrad.cholesky(Ybr)
    end

    # get the flow matrix
    Yfr  = Ybs*Er
    YfrT = copy(Yfr')

    # build the low-rank contingecy updates
    #
    # base: Y_b*theta_b = p
    # ctg:  Y_c*theta_c = p
    #       Y_c = Y_b + uk'*uk
    ctg_out_ind = Dict(ctg_ii => Vector{Int64}(undef, length(prm.ctg.components[ctg_ii])) for ctg_ii in 1:sys.nctg)
    ctg_params  = Dict(ctg_ii => Vector{Float64}(undef, length(prm.ctg.components[ctg_ii])) for ctg_ii in 1:sys.nctg)
    
    # should we build the full ctg matrices?
    if qG.build_ctg_full == true
        Ybr_k = Dict(ctg_ii => QuasiGrad.spzeros(sys.nac,sys.nac) for ctg_ii in 1:sys.nctg)
    else
        # build something small of the correct data type
        Ybr_k = Dict(1 => QuasiGrad.spzeros(1,1))
    end

    # and/or, should we build the low rank ctg elements? yes.. (qG.build_ctg_lowrank == true)
    u_k = [zeros(sys.nb-1) for ctg_ii in 1:sys.nctg]
    g_k = zeros(sys.nctg)
    z_k = [zeros(sys.nac) for ctg_ii in 1:sys.nctg]

    # loop over components (see below for comments!!!)
    for ctg_ii in 1:sys.nctg
        cmpnts = prm.ctg.components[ctg_ii]
        for (cmp_ii,cmp) in enumerate(cmpnts)
            cmp_index = findfirst(x -> x == cmp, ac_ids) 
            ctg_out_ind[ctg_ii][cmp_ii] = cmp_index
            ctg_params[ctg_ii][cmp_ii]  = -ac_b_params[cmp_index]
        end
    end

    # initialize state vectors for holding cg! results. first, standard base-case power flow solver:
    #   ** build early so we can use it! **
    x                 = randn(sys.nb-1) # using this format just to match "cg.jl"
    # => note -- the first array does NOT need to be zero'd out at each iteration, it seems
    pf_cg_statevars   = [QuasiGrad.IterativeSolvers.CGStateVariables(zero(x), similar(x), similar(x)) for tii in prm.ts.time_keys]
    grad_cg_statevars = [QuasiGrad.IterativeSolvers.CGStateVariables(zero(x), similar(x), similar(x)) for ii in 1:(qG.num_threads+2)]

    # set up a spin-lock to share memory buffers!
    wmi_tol      = qG.pcg_tol/10.0  # use higher tolerance here
    wmi_its      = 2*qG.max_pcg_its # allow for more iterations
    ready_to_use = ones(Bool, qG.num_threads+2)
    lck          = Threads.SpinLock()
    zrs          = [zeros(sys.nb-1) for _ in 1:(qG.num_threads+2)]
    t1           = time()
    
    # loop
    Threads.@threads for ctg_ii in 1:sys.nctg
        # use a custom "thread ID" -- three indices: tii, ctg_ii, and thrID
        thrID = 1
        Threads.lock(lck)
            thrIdx = findfirst(ready_to_use)
            if thrIdx != Nothing
                thrID = thrIdx
            end
            ready_to_use[thrID] = false # now in use :)
        Threads.unlock(lck)
    
        # apply sparse 
        zrs[thrID] .= @view Er[ctg_out_ind[ctg_ii][1],:]
        
        # compute u, g, and z!
            # => previous direct computation: u_k[ctg_ii]        .= Ybr_Ch\Er[ctg_out_ind[ctg_ii][1],:]
        QuasiGrad.cg!(u_k[ctg_ii], Ybr, zrs[thrID], statevars = grad_cg_statevars[thrID], abstol = wmi_tol, Pl=Ybr_ChPr, maxiter = wmi_its)
        @turbo g_k[ctg_ii]  = -ac_b_params[ctg_out_ind[ctg_ii][1]]/(1.0+(QuasiGrad.dot(Er[ctg_out_ind[ctg_ii][1],:],u_k[ctg_ii]))*-ac_b_params[ctg_out_ind[ctg_ii][1]])
        @turbo QuasiGrad.mul!(z_k[ctg_ii], Yfr, u_k[ctg_ii])
    
        # all done!!
        Threads.lock(lck)
            ready_to_use[thrID] = true
        Threads.unlock(lck)
    end

    t_ctg = time() - t1
    println("WMI factor solve time: $t_ctg")

    # phase shift derivatives
    #   => consider power injections:  pinj = (p_pr-p_cs-p_sh-p_fr_dc-p_to_dc-alpha*slack) + Er^T*phi*b
    #      => Er^T*phi*b
    # ~ skip the reference bus! -- fr_buses = positive in the incidence matrix; to_buses = negative..
    xfm_at_bus      = Dict(bus => vcat(idx.bus_is_xfm_frs[bus],idx.bus_is_xfm_tos[bus]) for bus in 2:sys.nb)
    xfm_at_bus_sign = Dict(bus => vcat(idx.bus_is_xfm_frs[bus],-idx.bus_is_xfm_tos[bus]) for bus in 2:sys.nb)
    xfm_phi_scalars = Dict(bus => ac_b_params[xfm_at_bus[bus] .+ sys.nl].*sign.(xfm_at_bus_sign[bus]) for bus in 2:sys.nb)

    # compute the constant acline Ybus matrix
    Ybus_acline_real, Ybus_acline_imag, Yflow_acline_series_real, Yflow_acline_series_imag, 
        Yflow_acline_shunt_fr_real, Yflow_acline_shunt_fr_imag, Yflow_acline_shunt_to_real, 
        Yflow_acline_shunt_to_imag = QuasiGrad.initialize_acline_Ybus(idx, prm, stt, sys)

    # other network matrices
    Ybus_real                = [spzeros(sys.nb,sys.nb)     for tii in prm.ts.time_keys]
    Ybus_imag                = [spzeros(sys.nb,sys.nb)     for tii in prm.ts.time_keys]
    Ybus_xfm_imag            = [spzeros(sys.nb,sys.nb)     for tii in prm.ts.time_keys]
    Ybus_shunt_imag          = [spzeros(sys.nb,sys.nb)     for tii in prm.ts.time_keys]
    Ybus_xfm_real            = [spzeros(sys.nb,sys.nb)     for tii in prm.ts.time_keys]
    Ybus_shunt_real          = [spzeros(sys.nb,sys.nb)     for tii in prm.ts.time_keys]
    Yflow_xfm_series_fr_real = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_xfm_series_fr_imag = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_xfm_series_to_real = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_xfm_series_to_imag = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_xfm_shunt_fr_real  = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_xfm_shunt_fr_imag  = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_xfm_shunt_to_real  = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_xfm_shunt_to_imag  = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_fr_real            = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_fr_imag            = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_to_real            = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Yflow_to_imag            = [spzeros(sys.nac,sys.nb)    for tii in prm.ts.time_keys]
    Jac                      = [spzeros(2*sys.nb,2*sys.nb) for tii in prm.ts.time_keys]
    Jac_pq_flow_fr           = [spzeros(2*sys.nac,2*sys.nb) for tii in prm.ts.time_keys]
    Jac_pq_flow_to           = [spzeros(2*sys.nac,2*sys.nb) for tii in prm.ts.time_keys]
    Jac_sflow_fr             = [spzeros(sys.nac,2*sys.nb) for tii in prm.ts.time_keys]
    Jac_sflow_to             = [spzeros(sys.nac,2*sys.nb) for tii in prm.ts.time_keys]

    # network parameters
    ntk = QuasiGrad.Network(
            s_max_ctg,     # max contingency flows
            E,             # full incidence matrix
            Efr,           # Efr = 0.5*(E + abs(E)) = E1
            Eto,           # Eto = 0.5*(abs(E) - E) = E2
            Er,            # reduced incidence matrix
            ErT,           # Er transposed :)
            Yb,            # full Ybus (DC)    
            Ybr,           # reduced Ybus (DC)
            Yfr,           # reduced flow matrix (DC)
            YfrT,          # Yfr transposed
            ctg_out_ind,   # for each ctg, the list of line indices
            ctg_params,    # for each ctg, the list of (negative) params
            Ybr_k,         # if build_ctg == true, reduced admittance matrix for each ctg 
            ac_b_params,   # base case susceptance parameters
            xfm_at_bus,
            xfm_phi_scalars,
            prm.ctg.alpha,
            prm.ctg.components,
            prm.ctg.id,
            prm.ctg.ctg_inds,
            Ybr_Ch,           # base case Cholesky
            Ybr_ChPr,         # base case preconditioner (everyone uses it!)
            u_k,              # low rank update vector: u_k = Y\v, w_k = b*u/(1+v'*u*b)
            g_k,              # low rank update scalar: g_k = b/(1+v'*u*b)
            z_k,              # Yflow*u_k
            Ybus_acline_real, # constant acline Ybus 
            Ybus_acline_imag, # constant acline Ybus
            Yflow_acline_series_real,    # constant acline (series)
            Yflow_acline_series_imag,    # constant acline (series)
            Yflow_acline_shunt_fr_real,  # constant acline (shunt)
            Yflow_acline_shunt_fr_imag,  # constant acline (shunt)
            Yflow_acline_shunt_to_real,  # constant acline (shunt)
            Yflow_acline_shunt_to_imag,  # constant acline (shunt)
            Ybus_real,
            Ybus_imag,
            Ybus_xfm_imag,
            Ybus_shunt_imag,
            Ybus_xfm_real,
            Ybus_shunt_real,
            Yflow_xfm_series_fr_real,  
            Yflow_xfm_series_fr_imag,  
            Yflow_xfm_series_to_real,  
            Yflow_xfm_series_to_imag,  
            Yflow_xfm_shunt_fr_real,
            Yflow_xfm_shunt_fr_imag,
            Yflow_xfm_shunt_to_real,
            Yflow_xfm_shunt_to_imag,
            Yflow_fr_real,
            Yflow_fr_imag,
            Yflow_to_real,
            Yflow_to_imag,
            Jac,
            Jac_pq_flow_fr,
            Jac_pq_flow_to,
            Jac_sflow_fr,  
            Jac_sflow_to)
    
    # flow data
    flw = QuasiGrad.Flow([zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [zeros(sys.nb)       for tii in prm.ts.time_keys],
                         [zeros(sys.nb-1)     for tii in prm.ts.time_keys],
                         [zeros(sys.nb-1)     for tii in prm.ts.time_keys],
                         [zeros(sys.nb-1)     for tii in prm.ts.time_keys],
                         [zeros(sys.nb-1)     for tii in prm.ts.time_keys],
                         [zeros(sys.nac)      for tii in prm.ts.time_keys],
                         [collect(1:sys.nctg) for tii in prm.ts.time_keys],
                         pf_cg_statevars)

    # contingency variables
    ctg = QuasiGrad.Contingency([zeros(sys.nb-1) for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nac)  for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nac)  for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nac)  for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nac)  for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nac)  for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nb-1) for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nb-1) for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nac)  for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nb-1) for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nac)  for ii in 1:(qG.num_threads+2)],
                                [zeros(sys.nac)  for ii in 1:(qG.num_threads+2)],
                                ones(Bool, qG.num_threads+2), # add two, for safety!
                                grad_cg_statevars)

    return ctg, ntk, flw
end

function build_incidence(idx::QuasiGrad.Index, prm::QuasiGrad.Param, stt::QuasiGrad.State, sys::QuasiGrad.System)
    # loop over all ac devices and construct incidence matrix
    m = sys.nac
    n = sys.nb

    # acline
    row_acline    = prm.acline.line_inds
    col_acline_fr = idx.acline_fr_bus
    col_acline_to = idx.acline_to_bus
    E_acline_fr   = QuasiGrad.sparse(row_acline,col_acline_fr, 1, m, n)
    E_acline_to   = QuasiGrad.sparse(row_acline,col_acline_to, -1, m, n)

    # get the indices of the lines which are off and zero them out
    lines_off = findall(stt.u_on_acline[1] .== 0)
    for line in lines_off
        E_acline_fr[line, col_acline_fr[line]] = 0.0
        E_acline_to[line, col_acline_to[line]] = 0.0
    end

    # xfm
    row_xfm    = sys.nl .+ prm.xfm.xfm_inds
    col_xfm_fr = idx.xfm_fr_bus
    col_xfm_to = idx.xfm_to_bus
    E_xfm_fr   = QuasiGrad.sparse(row_xfm,col_xfm_fr, 1, m, n)
    E_xfm_to   = QuasiGrad.sparse(row_xfm,col_xfm_to, -1, m, n)

    # get the indices of the xfms which are off and zero them out
    xfms_off = findall(stt.u_on_xfm[1] .== 0)
    for xfm in xfms_off
        E_xfm_fr[xfm + sys.nl, col_xfm_fr[xfm]] = 0.0
        E_xfm_to[xfm + sys.nl, col_xfm_to[xfm]] = 0.0
    end

    # combine the output
    E = E_acline_fr + E_acline_to + E_xfm_fr + E_xfm_to

    # Now, also build E1 = Efr and E2 = Eto
    Efr = +E_acline_fr + E_xfm_fr # E1
    Eto = -E_acline_to - E_xfm_to # E2

    # output
    return E, Efr, Eto
end

function initialize_acline_Ybus(idx::QuasiGrad.Index, prm::QuasiGrad.Param, stt::QuasiGrad.State, sys::QuasiGrad.System)
    # loop over all ac devices and construct incidence matrix
    #
    # note: this assumes all lines are on!
    m = sys.nac
    n = sys.nb

    # full: Ybus = Ybus_acline + Ybus_xfm + Ybus_shunts
    # => Ybus_acline   = spzeros(n,n) # constant!!
    # => Ybus_xfm      = spzeros(n,n) # time varying
    # => Ybus_shunt    = spzeros(n,n) # time varying

    # acline ===========================
    row_acline    = prm.acline.line_inds
    col_acline_fr = idx.acline_fr_bus
    col_acline_to = idx.acline_to_bus
    E_acline_fr   = QuasiGrad.sparse(row_acline,col_acline_fr, 1, m, n)
    E_acline_to   = QuasiGrad.sparse(row_acline,col_acline_to, -1, m, n)

    # get the indices of the lines which are off and zero them out
    lines_off = findall(stt.u_on_acline[1] .== 0)
    for line in lines_off
        E_acline_fr[line, col_acline_fr[line]] = 0.0
        E_acline_to[line, col_acline_to[line]] = 0.0
    end
    
    # build E
    E_acline = E_acline_fr + E_acline_to

    # build diagonal admittance matrices
    Yd_acline_series = QuasiGrad.spdiagm(m, m, prm.acline.g_sr + im*prm.acline.b_sr) # zero pads!
    Yd_acline_shunt  = QuasiGrad.spzeros(Complex{Float64}, n, n)

    # loop and populate
    for line in 1:sys.nl
        if line in lines_off
            # skip!! actually, remove the corresponding line in Yd_acline_series
            Yd_acline_series[line,line] = 0.0
        else
            fr = idx.acline_fr_bus[line]
            to = idx.acline_to_bus[line]

            # fr first
            Yd_acline_shunt[fr,fr] += prm.acline.g_fr[line]
            Yd_acline_shunt[fr,fr] += im*prm.acline.b_fr[line]
            Yd_acline_shunt[fr,fr] += im*prm.acline.b_ch[line]/2.0

            # to second
            Yd_acline_shunt[to,to] += prm.acline.g_to[line]
            Yd_acline_shunt[to,to] += im*prm.acline.b_to[line]
            Yd_acline_shunt[to,to] += im*prm.acline.b_ch[line]/2.0
        end
    end

    # output
    Ybus_acline      = E_acline'*Yd_acline_series*E_acline + Yd_acline_shunt
    Ybus_acline_real = real(Ybus_acline)
    Ybus_acline_imag = imag(Ybus_acline)

    # ========================================= #
    # for the purposes of building line flow matrices, also compute series and line shunt matrices
    Yflow_acline_series_real   = real(Yd_acline_series*E_acline)
    Yflow_acline_series_imag   = imag(Yd_acline_series*E_acline)
    Yflow_acline_shunt_fr_real = QuasiGrad.spzeros(Complex{Float64}, m, n)
    Yflow_acline_shunt_fr_imag = QuasiGrad.spzeros(Complex{Float64}, m, n)
    Yflow_acline_shunt_to_real = QuasiGrad.spzeros(Complex{Float64}, m, n)
    Yflow_acline_shunt_to_imag = QuasiGrad.spzeros(Complex{Float64}, m, n)

    # loop and populate
    for line in 1:sys.nl
        if line in lines_off
            # skip!!
        else
            fr = idx.acline_fr_bus[line]
            to = idx.acline_to_bus[line]

            # fr first
            Yflow_acline_shunt_fr_real[line,fr] += prm.acline.g_fr[line]
            Yflow_acline_shunt_fr_imag[line,fr] += prm.acline.b_fr[line]
            Yflow_acline_shunt_fr_imag[line,fr] += prm.acline.b_ch[line]/2.0

            # to second
            Yflow_acline_shunt_to_real[line,to] += prm.acline.g_to[line]
            Yflow_acline_shunt_to_imag[line,to] += prm.acline.b_to[line]
            Yflow_acline_shunt_to_imag[line,to] += prm.acline.b_ch[line]/2.0
        end
    end

    # output
    return Ybus_acline_real, Ybus_acline_imag, Yflow_acline_series_real, Yflow_acline_series_imag, Yflow_acline_shunt_fr_real, Yflow_acline_shunt_fr_imag, Yflow_acline_shunt_to_real, Yflow_acline_shunt_to_imag
end

function update_Ybus!(idx::QuasiGrad.Index, ntk::QuasiGrad.Network, prm::QuasiGrad.Param, stt::QuasiGrad.State, sys::QuasiGrad.System, tii::Int8)
    # this function updates the Ybus matrix using the time-varying shunt and xfm values
    #
    # NOTE: this assumes all xfms are on
    n = sys.nb
    ntk.Ybus_xfm_imag[tii]   .= spzeros(n,n)
    ntk.Ybus_shunt_imag[tii] .= spzeros(n,n)
    ntk.Ybus_xfm_real[tii]   .= spzeros(n,n)
    ntk.Ybus_shunt_real[tii] .= spzeros(n,n)
    #
    xfms_off = findall(stt.u_on_xfm[1] .== 0.0)
    # xfm ===========================
    for xfm in 1:sys.nx
        if xfm in xfms_off
            # skip!! no contribution :)
        else
            # prepare
            cos_phi  = cos(stt.phi[tii][xfm])
            sin_phi  = sin(stt.phi[tii][xfm])
            series_y = prm.xfm.g_sr[xfm] + im*prm.xfm.b_sr[xfm]

            # populate!
            yff = (series_y + im*prm.xfm.b_ch[xfm]/2.0 + prm.xfm.g_fr[xfm] + im*prm.xfm.b_fr[xfm])/(stt.tau[tii][xfm]^2)
            ytt = (series_y + im*prm.xfm.b_ch[xfm]/2.0 + prm.xfm.g_to[xfm] + im*prm.xfm.b_to[xfm])
            yft = (-series_y)/(stt.tau[tii][xfm]*(cos_phi - im*sin_phi))
            ytf = (-series_y)/(stt.tau[tii][xfm]*(cos_phi + im*sin_phi))
        
            # populate real!
            ntk.Ybus_xfm_real[tii][idx.xfm_fr_bus[xfm], idx.xfm_fr_bus[xfm]] += real(yff)
            ntk.Ybus_xfm_real[tii][idx.xfm_to_bus[xfm], idx.xfm_to_bus[xfm]] += real(ytt)
            ntk.Ybus_xfm_real[tii][idx.xfm_fr_bus[xfm], idx.xfm_to_bus[xfm]] += real(yft)
            ntk.Ybus_xfm_real[tii][idx.xfm_to_bus[xfm], idx.xfm_fr_bus[xfm]] += real(ytf)

            # populate imag
            ntk.Ybus_xfm_imag[tii][idx.xfm_fr_bus[xfm], idx.xfm_fr_bus[xfm]] += imag(yff)
            ntk.Ybus_xfm_imag[tii][idx.xfm_to_bus[xfm], idx.xfm_to_bus[xfm]] += imag(ytt)
            ntk.Ybus_xfm_imag[tii][idx.xfm_fr_bus[xfm], idx.xfm_to_bus[xfm]] += imag(yft)
            ntk.Ybus_xfm_imag[tii][idx.xfm_to_bus[xfm], idx.xfm_fr_bus[xfm]] += imag(ytf)
        end
    end

    # shunt ===========================
    for shunt in 1:sys.nsh
        bus = idx.shunt_bus[shunt]
        ntk.Ybus_shunt_real[tii][bus,bus] += prm.shunt.gs[shunt]*(stt.u_step_shunt[tii][shunt])
        ntk.Ybus_shunt_imag[tii][bus,bus] += prm.shunt.bs[shunt]*(stt.u_step_shunt[tii][shunt])
    end

    # construct the output
    ntk.Ybus_real[tii] .= ntk.Ybus_acline_real .+ ntk.Ybus_xfm_real[tii] .+ ntk.Ybus_shunt_real[tii]
    ntk.Ybus_imag[tii] .= ntk.Ybus_acline_imag .+ ntk.Ybus_xfm_imag[tii] .+ ntk.Ybus_shunt_imag[tii]
end

function update_Yflow!(idx::QuasiGrad.Index, ntk::QuasiGrad.Network, prm::QuasiGrad.Param, stt::QuasiGrad.State, sys::QuasiGrad.System, tii::Int8)
    # this function updates the Yflow matrix using the time-varying shunt and xfm values
    #
    # Pfr, Qfr = (Efr*V).*conj((Yflow_series_fr + Yflow_shunt_fr)*V), with V = phasor
    # Pto, Qto = (Eto*V).*conj((Yflow_series_to + Yflow_shunt_to)*V), with V = phasor
    #
    # NOTE: this assumes all xfms are on
    ntk.Yflow_xfm_series_fr_real[tii] .= spzeros(sys.nac,sys.nb)
    ntk.Yflow_xfm_series_fr_imag[tii] .= spzeros(sys.nac,sys.nb)
    ntk.Yflow_xfm_series_to_real[tii] .= spzeros(sys.nac,sys.nb)
    ntk.Yflow_xfm_series_to_imag[tii] .= spzeros(sys.nac,sys.nb)
    ntk.Yflow_xfm_shunt_fr_real[tii]  .= spzeros(sys.nac,sys.nb)
    ntk.Yflow_xfm_shunt_fr_imag[tii]  .= spzeros(sys.nac,sys.nb)
    ntk.Yflow_xfm_shunt_to_real[tii]  .= spzeros(sys.nac,sys.nb)
    ntk.Yflow_xfm_shunt_to_imag[tii]  .= spzeros(sys.nac,sys.nb)

    #
    xfms_off = findall(stt.u_on_xfm[1] .== 0.0)
    # xfm ===========================
    for xfm in 1:sys.nx
        if xfm in xfms_off
            # skip!! no contribution :)
        else
            # prepare
            cos_phi  = cos(stt.phi[tii][xfm])
            sin_phi  = sin(stt.phi[tii][xfm])
            series_y = prm.xfm.g_sr[xfm] + im*prm.xfm.b_sr[xfm]

            # series elements
            yff_series = (series_y)/(stt.tau[tii][xfm]^2)
            ytt_series = (series_y)
            yft_series = (-series_y)/(stt.tau[tii][xfm]*(cos_phi - im*sin_phi))
            ytf_series = (-series_y)/(stt.tau[tii][xfm]*(cos_phi + im*sin_phi))

            # shunt elements
            yff_shunt = (im*prm.xfm.b_ch[xfm]/2.0 + prm.xfm.g_fr[xfm] + im*prm.xfm.b_fr[xfm])/(stt.tau[tii][xfm]^2)
            ytt_shunt = (im*prm.xfm.b_ch[xfm]/2.0 + prm.xfm.g_to[xfm] + im*prm.xfm.b_to[xfm])

            # first, populate the series terms
            #
            # populate real!
            ntk.Yflow_xfm_series_fr_real[tii][xfm+sys.nl, idx.xfm_fr_bus[xfm]] += real(yff_series)
            ntk.Yflow_xfm_series_fr_real[tii][xfm+sys.nl, idx.xfm_to_bus[xfm]] += real(yft_series)
            ntk.Yflow_xfm_series_to_real[tii][xfm+sys.nl, idx.xfm_to_bus[xfm]] += real(ytt_series)
            ntk.Yflow_xfm_series_to_real[tii][xfm+sys.nl, idx.xfm_fr_bus[xfm]] += real(ytf_series)
            # populate imag
            ntk.Yflow_xfm_series_fr_imag[tii][xfm+sys.nl, idx.xfm_fr_bus[xfm]] += imag(yff_series)
            ntk.Yflow_xfm_series_fr_imag[tii][xfm+sys.nl, idx.xfm_to_bus[xfm]] += imag(yft_series)
            ntk.Yflow_xfm_series_to_imag[tii][xfm+sys.nl, idx.xfm_to_bus[xfm]] += imag(ytt_series)
            ntk.Yflow_xfm_series_to_imag[tii][xfm+sys.nl, idx.xfm_fr_bus[xfm]] += imag(ytf_series)

            # second, populate the shunt terms
            ntk.Yflow_xfm_shunt_fr_real[tii][xfm+sys.nl, idx.xfm_fr_bus[xfm]] += real(yff_shunt)
            ntk.Yflow_xfm_shunt_to_real[tii][xfm+sys.nl, idx.xfm_to_bus[xfm]] += real(ytt_shunt)
            # populate imag
            ntk.Yflow_xfm_shunt_fr_imag[tii][xfm+sys.nl, idx.xfm_fr_bus[xfm]] += imag(yff_shunt)
            ntk.Yflow_xfm_shunt_to_imag[tii][xfm+sys.nl, idx.xfm_to_bus[xfm]] += imag(ytt_shunt)
        end
    end

    # construct the output -- Yflow_real and Yflow_imag are the full matrices
    #                         which map nodal voltage vectors to p/q lines flows
    #                         via: (E1*V).*conj(Yflow*V), with V = phasor
    ntk.Yflow_fr_real[tii] .=  ntk.Yflow_acline_series_real .+ ntk.Yflow_xfm_series_fr_real[tii] .+ ntk.Yflow_acline_shunt_fr_real .+ ntk.Yflow_xfm_shunt_fr_real[tii]
    ntk.Yflow_fr_imag[tii] .=  ntk.Yflow_acline_series_imag .+ ntk.Yflow_xfm_series_fr_imag[tii] .+ ntk.Yflow_acline_shunt_fr_imag .+ ntk.Yflow_xfm_shunt_fr_imag[tii]
    ntk.Yflow_to_real[tii] .= -ntk.Yflow_acline_series_real .+ ntk.Yflow_xfm_series_to_real[tii] .+ ntk.Yflow_acline_shunt_to_real .+ ntk.Yflow_xfm_shunt_to_real[tii]
    ntk.Yflow_to_imag[tii] .= -ntk.Yflow_acline_series_imag .+ ntk.Yflow_xfm_series_to_imag[tii] .+ ntk.Yflow_acline_shunt_to_imag .+ ntk.Yflow_xfm_shunt_to_imag[tii]
end

# get the "must run" times
function get_tmr(dev::Int64, prm::QuasiGrad.Param)
    # two cases (mutually exclusive) -- test which is applicable
    if prm.dev.init_accu_down_time[dev] > 0
        t_set = prm.ts.time_keys[isapprox.(prm.dev.on_status_lb[dev],1.0)]

    else  # necessarily true -> prm.dev.init_accu_up_time[dev] > 0
        mr_up       = prm.dev.init_accu_up_time[dev] .+ prm.ts.start_time .+ QuasiGrad.eps_time .< prm.dev.in_service_time_lb[dev]
        valid_times = isapprox.(prm.dev.on_status_lb[dev],1.0) .|| mr_up
        t_set       = prm.ts.time_keys[valid_times]
    end

    # output
    return t_set 
end

# get the "must run" times
function get_tout(dev::Int64, prm::QuasiGrad.Param)
    # two cases (mutually exclusive) -- test which is applicable
    if prm.dev.init_accu_up_time[dev] > 0
        t_set = prm.ts.time_keys[isapprox.(prm.dev.on_status_ub[dev],0.0)]

    else  # necessarily true -> prm.dev.init_accu_down_time[dev] > 0
        out_dwn     = prm.dev.init_accu_down_time[dev] .+ prm.ts.start_time .+ QuasiGrad.eps_time .< prm.dev.down_time_lb[dev]
        valid_times = isapprox.(prm.dev.on_status_ub[dev],0.0) .|| out_dwn
        t_set       = prm.ts.time_keys[valid_times]
    end
    
    # output
    return t_set
end

# depricated!! left here for historical purposes :)
function initialize_static_grads!(idx::QuasiGrad.Index, grd::QuasiGrad.Grad, sys::QuasiGrad.System, qG::QuasiGrad.QG)
    # there is a subset of gradients whose values are static:
    # set those static gradients here!
    #
    # negative market surplus function: see score_zms!()
    grd[:nzms][:zbase]    = -1.0
    grd[:nzms][:zctg_min] = -1.0
    grd[:nzms][:zctg_avg] = -1.0

    # zbase: see score_zbase!()
    grd[:zbase][:zt]        = 1.0
    grd[:zbase][:z_enmax]   = 1.0
    grd[:zbase][:z_enmin]   = 1.0
    grd[:zbase][:zhat_mxst] = -qG.constraint_grad_weight

    # zt: see score_zt!()
    #
    # consumer revenues and costs
    grd[:zt][:zen_dev][idx.cs_devs] = +ones(sys.ncs)
    grd[:zt][:zen_dev][idx.pr_devs] = -ones(sys.npr)
    # startup costs
    grd[:zt][:zsu_dev]    = -1.0
    grd[:zt][:zsu_acline] = -1.0
    grd[:zt][:zsu_xfm]    = -1.0
    # shutdown costs
    grd[:zt][:zsd_dev]    = -1.0
    grd[:zt][:zsd_acline] = -1.0
    grd[:zt][:zsd_xfm]    = -1.0
    # on-costs
    grd[:zt][:zon_dev]    = -1.0
    # time-dependent su costs
    grd[:zt][:zsus_dev]   = -1.0
    # ac line overload costs
    grd[:zt][:zs_acline]  = -1.0
    grd[:zt][:zs_xfm]     = -1.0
    # local reserve penalties (producers and consumers)
    grd[:zt][:zrgu] = -1.0
    grd[:zt][:zrgd] = -1.0
    grd[:zt][:zscr] = -1.0
    grd[:zt][:znsc] = -1.0
    grd[:zt][:zrru] = -1.0
    grd[:zt][:zrrd] = -1.0
    grd[:zt][:zqru] = -1.0
    grd[:zt][:zqrd] = -1.0
    # power mismatch penalties
    grd[:zt][:zp] = -1.0
    grd[:zt][:zq] = -1.0
    # zonal reserve penalties (P)
    grd[:zt][:zrgu_zonal] = -1.0
    grd[:zt][:zrgd_zonal] = -1.0
    grd[:zt][:zscr_zonal] = -1.0
    grd[:zt][:znsc_zonal] = -1.0
    grd[:zt][:zrru_zonal] = -1.0
    grd[:zt][:zrrd_zonal] = -1.0
    # zonal reserve penalties (Q)
    grd[:zt][:zqru_zonal] = -1.0
    grd[:zt][:zqrd_zonal] = -1.0

    grd[:zt][:zhat_mndn]   = -qG.constraint_grad_weight
    grd[:zt][:zhat_mnup]   = -qG.constraint_grad_weight
    grd[:zt][:zhat_rup]    = -qG.constraint_grad_weight
    grd[:zt][:zhat_rd]     = -qG.constraint_grad_weight
    grd[:zt][:zhat_rgu]    = -qG.constraint_grad_weight
    grd[:zt][:zhat_rgd]    = -qG.constraint_grad_weight
    grd[:zt][:zhat_scr]    = -qG.constraint_grad_weight
    grd[:zt][:zhat_nsc]    = -qG.constraint_grad_weight
    grd[:zt][:zhat_rruon]  = -qG.constraint_grad_weight
    grd[:zt][:zhat_rruoff] = -qG.constraint_grad_weight
    grd[:zt][:zhat_rrdon]  = -qG.constraint_grad_weight
    grd[:zt][:zhat_rrdoff] = -qG.constraint_grad_weight
    # common set of pr and cs constraint variables (see below)
    grd[:zt][:zhat_pmax]      = -qG.constraint_grad_weight
    grd[:zt][:zhat_pmin]      = -qG.constraint_grad_weight
    grd[:zt][:zhat_pmaxoff]   = -qG.constraint_grad_weight
    grd[:zt][:zhat_qmax]      = -qG.constraint_grad_weight
    grd[:zt][:zhat_qmin]      = -qG.constraint_grad_weight
    grd[:zt][:zhat_qmax_beta] = -qG.constraint_grad_weight
    grd[:zt][:zhat_qmin_beta] = -qG.constraint_grad_weight

    # for testing the connection costs
    # prm.acline.connection_cost    .= 1000000.0
    # prm.acline.disconnection_cost .= 1000000.0
    # prm.xfm.connection_cost       .= 1000000.0
    # prm.xfm.disconnection_cost    .= 1000000.0
end

function initialize_adam_states(prm::QuasiGrad.Param, qG::QuasiGrad.QG, sys::QuasiGrad.System)
    # build the adm dictionary, which has the same set of
    # entries (keys) as the mgd dictionary
    keys = [:vm, :va, :tau, :phi, :dc_pfr, :dc_qfr, :dc_qto, :u_on_acline, :u_on_xfm,
            :u_step_shunt, :u_on_dev, :p_on, :dev_q, :p_rgu, :p_rgd, :p_scr, :p_nsc,
            :p_rru_on, :p_rrd_on, :p_rru_off, :p_rrd_off, :q_qru, :q_qrd]
    vm = QuasiGrad.MV([zeros(sys.nb) for tii in prm.ts.time_keys],
                      [zeros(sys.nb) for tii in prm.ts.time_keys])
    va = QuasiGrad.MV([zeros(sys.nb) for tii in prm.ts.time_keys],
                      [zeros(sys.nb) for tii in prm.ts.time_keys])
    tau = QuasiGrad.MV([zeros(sys.nx) for tii in prm.ts.time_keys],
                       [zeros(sys.nx) for tii in prm.ts.time_keys])
    phi = QuasiGrad.MV([zeros(sys.nx) for tii in prm.ts.time_keys],
                       [zeros(sys.nx) for tii in prm.ts.time_keys])
    dc_pfr = QuasiGrad.MV([zeros(sys.nldc) for tii in prm.ts.time_keys],
                          [zeros(sys.nldc) for tii in prm.ts.time_keys])
    dc_qfr = QuasiGrad.MV([zeros(sys.nldc) for tii in prm.ts.time_keys],
                          [zeros(sys.nldc) for tii in prm.ts.time_keys])
    dc_qto = QuasiGrad.MV([zeros(sys.nldc) for tii in prm.ts.time_keys],
                          [zeros(sys.nldc) for tii in prm.ts.time_keys])
    u_on_acline = QuasiGrad.MV([zeros(sys.nl) for tii in prm.ts.time_keys],
                               [zeros(sys.nl) for tii in prm.ts.time_keys])
    u_on_xfm = QuasiGrad.MV([zeros(sys.nx) for tii in prm.ts.time_keys],
                            [zeros(sys.nx) for tii in prm.ts.time_keys])
    u_step_shunt = QuasiGrad.MV([zeros(sys.nsh) for tii in prm.ts.time_keys],
                                [zeros(sys.nsh) for tii in prm.ts.time_keys])
    u_on_dev = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                            [zeros(sys.ndev) for tii in prm.ts.time_keys])
    p_on = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                        [zeros(sys.ndev) for tii in prm.ts.time_keys])
    dev_q = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                         [zeros(sys.ndev) for tii in prm.ts.time_keys])
    p_rgu = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                         [zeros(sys.ndev) for tii in prm.ts.time_keys])
    p_rgd = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                         [zeros(sys.ndev) for tii in prm.ts.time_keys])
    p_scr = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                         [zeros(sys.ndev) for tii in prm.ts.time_keys])
    p_nsc = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                         [zeros(sys.ndev) for tii in prm.ts.time_keys])
    p_rru_on = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                            [zeros(sys.ndev) for tii in prm.ts.time_keys])
    p_rrd_on = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                            [zeros(sys.ndev) for tii in prm.ts.time_keys])
    p_rru_off = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                             [zeros(sys.ndev) for tii in prm.ts.time_keys]) 
    p_rrd_off = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                             [zeros(sys.ndev) for tii in prm.ts.time_keys])
    q_qru = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                         [zeros(sys.ndev) for tii in prm.ts.time_keys])
    q_qrd = QuasiGrad.MV([zeros(sys.ndev) for tii in prm.ts.time_keys],
                         [zeros(sys.ndev) for tii in prm.ts.time_keys])

    # build the adam struct
    adm = QuasiGrad.Adam(keys, vm, va, tau, phi, dc_pfr, dc_qfr, dc_qto, u_on_acline,
                         u_on_xfm, u_step_shunt, u_on_dev, p_on, dev_q, p_rgu,
                         p_rgd, p_scr, p_nsc, p_rru_on, p_rrd_on, p_rru_off, 
                         p_rrd_off, q_qru, q_qrd)
                                      
    return adm
end

function build_state(prm::QuasiGrad.Param, sys::QuasiGrad.System, qG::QuasiGrad.QG)

    # how many ctg states do we need?
    num_wrst = Int64(ceil(qG.frac_ctg_keep*sys.nctg/2))  # in case n_ctg is odd, and we want to keep all!
    num_rnd  = Int64(floor(qG.frac_ctg_keep*sys.nctg/2)) # in case n_ctg is odd, and we want to keep all!
    num_ctg  = num_wrst + num_rnd

    # stt -- use initial values
    stt = QuasiGrad.State(
        [ones(sys.nb)              for tii in prm.ts.time_keys],
        [ones(sys.nb)              for tii in prm.ts.time_keys],         
        [copy(prm.bus.init_va)     for tii in prm.ts.time_keys],
        [copy(prm.bus.init_va)     for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],            
        [zeros(sys.nl)             for tii in prm.ts.time_keys],            
        [zeros(sys.nl)             for tii in prm.ts.time_keys],            
        [zeros(sys.nl)             for tii in prm.ts.time_keys],            
        [prm.acline.init_on_status for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],           
        [zeros(sys.nl)             for tii in prm.ts.time_keys],           
        [copy(prm.xfm.init_phi)    for tii in prm.ts.time_keys],
        [copy(prm.xfm.init_tau)    for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],       
        [zeros(sys.nx)             for tii in prm.ts.time_keys],       
        [zeros(sys.nx)             for tii in prm.ts.time_keys],       
        [zeros(sys.nx)             for tii in prm.ts.time_keys],       
        [prm.xfm.init_on_status    for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],        
        [zeros(sys.nx)             for tii in prm.ts.time_keys],        
        [copy(prm.dc.init_pdc_fr)  for tii in prm.ts.time_keys], 
        [copy(-prm.dc.init_pdc_fr) for tii in prm.ts.time_keys], 
        [copy(prm.dc.init_qdc_fr)  for tii in prm.ts.time_keys], 
        [copy(prm.dc.init_qdc_to)  for tii in prm.ts.time_keys], 
        [zeros(sys.nsh)            for tii in prm.ts.time_keys], 
        [zeros(sys.nsh)            for tii in prm.ts.time_keys], 
        [zeros(sys.nsh)            for tii in prm.ts.time_keys], 
        [ones(sys.ndev)            for tii in prm.ts.time_keys],   # u_on_dev
        [ones(sys.nT)              for ii in 1:sys.ndev], # u_on_dev_Trx
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],   # dev_p
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],   # dev_q
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],   # dev_q_copy
        [ones(sys.ndev)            for tii in prm.ts.time_keys],   # u_on_dev_GRB
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],   # u_su_dev
        [zeros(sys.nT)             for ii in 1:sys.ndev], # u_su_dev_Trx
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],   # u_sd_dev
        [zeros(sys.nT)             for ii in 1:sys.ndev], # u_sd_dev_Trx
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],   # u_sum
        [zeros(sys.nT)             for ii in 1:sys.ndev], # u_sum_Trx
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.nctg)           for tii in prm.ts.time_keys], 
        [zeros(num_ctg)            for tii in prm.ts.time_keys],
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.nl)             for tii in prm.ts.time_keys], 
        [zeros(sys.nx)             for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.nl)             for tii in prm.ts.time_keys], 
        [zeros(sys.nx)             for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.nl)             for tii in prm.ts.time_keys], 
        [zeros(sys.nx)             for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.nb)             for tii in prm.ts.time_keys], 
        [zeros(sys.nb)             for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzQ)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzQ)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzP)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzQ)            for tii in prm.ts.time_keys], 
        [zeros(sys.nzQ)            for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],
        [zeros(sys.ndev)           for tii in prm.ts.time_keys], 
        [zeros(sys.ndev)           for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nb)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys], 
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nl)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nx)             for tii in prm.ts.time_keys],
        [zeros(sys.nsh)            for tii in prm.ts.time_keys],
        [zeros(sys.nsh)            for tii in prm.ts.time_keys],
        [zeros(sys.nsh)            for tii in prm.ts.time_keys],
        [[zeros(prm.dev.num_sus[dev]) for dev in 1:(sys.ndev)] for tii in prm.ts.time_keys],
        [[zeros(prm.dev.num_sus[dev]) for dev in 1:(sys.ndev)] for tii in prm.ts.time_keys],
        zeros(sys.ndev),
        zeros(sys.ndev),
        zeros(sys.ndev),
        [zeros(sys.ndev) for tii in prm.ts.time_keys],
        [zeros(sys.ndev) for tii in prm.ts.time_keys],
        [zeros(sys.ndev) for tii in prm.ts.time_keys],
        [zeros(sys.ndev) for tii in prm.ts.time_keys],
        [zeros(sys.nb)   for tii in prm.ts.time_keys],
        [zeros(sys.nb)   for tii in prm.ts.time_keys],
        [zeros(sys.nb)   for tii in prm.ts.time_keys],
        [zeros(sys.nb)   for tii in prm.ts.time_keys],
        [zeros(sys.nb)   for tii in prm.ts.time_keys],
        [zeros(sys.nb)   for tii in prm.ts.time_keys],
        [zeros(sys.nac)  for tii in prm.ts.time_keys],
        [zeros(sys.nac)  for tii in prm.ts.time_keys],
        [zeros(sys.nac)  for tii in prm.ts.time_keys],
        [zeros(sys.nac)  for tii in prm.ts.time_keys],
        [zeros(sys.nac)  for tii in prm.ts.time_keys],
        [zeros(sys.nac)  for tii in prm.ts.time_keys],
        [zeros(sys.nac)  for tii in prm.ts.time_keys],
        [zeros(sys.nac)  for tii in prm.ts.time_keys],
        [zeros(sys.nl)   for tii in prm.ts.time_keys],
        [zeros(sys.nl)   for tii in prm.ts.time_keys],
        [zeros(sys.nl)   for tii in prm.ts.time_keys],
        [zeros(sys.nl)   for tii in prm.ts.time_keys],
        [zeros(sys.nx)   for tii in prm.ts.time_keys],
        [zeros(sys.nx)   for tii in prm.ts.time_keys],
        [zeros(sys.nx)   for tii in prm.ts.time_keys],
        [zeros(sys.nx)   for tii in prm.ts.time_keys],
        zeros(sys.nT)) # parallel ed scores!

        # shunts -- should we use the supplied initialization? default: no!
        if qG.initialize_shunt_to_given_value
            for tii in prm.ts.time_keys
                stt.u_step_shunt[tii] .= copy.(prm.shunt.init_step)
            end
        end

        # vm -- should we use the supplied initialization? default: no!
        if qG.initialize_vm_to_given_value
            for tii in prm.ts.time_keys
                stt.vm[tii] .= copy.(prm.bus.init_vm)
            end
        else
            for tii in prm.ts.time_keys
                stt.vm[tii] .= 1.0
            end
        end

    # output
    return stt
end

function build_master_grad(prm::QuasiGrad.Param, sys::QuasiGrad.System)
    # mgd = master grad -- this is the gradient which relates the negative market surplus function 
    # with all "basis" variables -- i.e., the variables for which all others are computed.
    # These are *exactly* (I think..) the variables which are reported in the solution file
    mgd = QuasiGrad.MasterGrad(
        [zeros(sys.nb)   for tii in prm.ts.time_keys],       
        [zeros(sys.nb)   for tii in prm.ts.time_keys],         
        [zeros(sys.nx)   for tii in prm.ts.time_keys],         
        [zeros(sys.nx)   for tii in prm.ts.time_keys], 
        [zeros(sys.nldc) for tii in prm.ts.time_keys], 
        [zeros(sys.nldc) for tii in prm.ts.time_keys], 
        [zeros(sys.nldc) for tii in prm.ts.time_keys], 
        [zeros(sys.nl)   for tii in prm.ts.time_keys],  
        [zeros(sys.nx)   for tii in prm.ts.time_keys],  
        [zeros(sys.nsh)  for tii in prm.ts.time_keys],
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys], 
        [zeros(sys.ndev) for tii in prm.ts.time_keys])
    
    # output
    return mgd
end

function build_grad(prm::QuasiGrad.Param, sys::QuasiGrad.System)

    # first, build the mini component dicts
    acline_pfr = QuasiGrad.Acline_pfr(
        [zeros(sys.nl) for tii in prm.ts.time_keys],
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys])

    acline_qfr = QuasiGrad.Acline_qfr(
        [zeros(sys.nl) for tii in prm.ts.time_keys],
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys])
    
    acline_pto = QuasiGrad.Acline_pto(
        [zeros(sys.nl) for tii in prm.ts.time_keys],
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys])
    
    acline_qto = QuasiGrad.Acline_qto(
        [zeros(sys.nl) for tii in prm.ts.time_keys],
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys])
    
    zs_acline = QuasiGrad.Zs_acline(
        [zeros(sys.nl) for tii in prm.ts.time_keys],
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys], 
        [zeros(sys.nl) for tii in prm.ts.time_keys])
    
    xfm_pfr = QuasiGrad.Xfm_pfr(
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys])
    
    xfm_qfr = QuasiGrad.Xfm_qfr(
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys])
    
    xfm_pto = QuasiGrad.Xfm_pto(
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys])
    
    xfm_qto = QuasiGrad.Xfm_qto(
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys], 
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys])
    
    zs_xfm = QuasiGrad.Zs_xfm(
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys])
    
    sh_p = QuasiGrad.Sh_p(
        [zeros(sys.nsh) for tii in prm.ts.time_keys],
        [zeros(sys.nsh) for tii in prm.ts.time_keys])
    
    sh_q = QuasiGrad.Sh_q(
        [zeros(sys.nsh) for tii in prm.ts.time_keys],
        [zeros(sys.nsh) for tii in prm.ts.time_keys])
    
    zp = QuasiGrad.Zp(
        [zeros(sys.nb) for tii in prm.ts.time_keys])
    
    zq = QuasiGrad.Zq(
        [zeros(sys.nb) for tii in prm.ts.time_keys])
    
    zen_dev = QuasiGrad.Zen_dev(
        [zeros(sys.ndev) for tii in prm.ts.time_keys])
    
    u_su_dev = QuasiGrad.U_su_dev(
        [zeros(sys.ndev) for tii in prm.ts.time_keys],
        [zeros(sys.ndev) for tii in prm.ts.time_keys])
    
    u_sd_dev = QuasiGrad.U_sd_dev(
        [zeros(sys.ndev) for tii in prm.ts.time_keys],
        [zeros(sys.ndev) for tii in prm.ts.time_keys])
    
    u_su_acline = QuasiGrad.U_su_acline(
        [zeros(sys.nl) for tii in prm.ts.time_keys],
        [zeros(sys.nl) for tii in prm.ts.time_keys])
    
    u_sd_acline = QuasiGrad.U_sd_acline(
        [zeros(sys.nl) for tii in prm.ts.time_keys],
        [zeros(sys.nl) for tii in prm.ts.time_keys])
    
    u_su_xfm = QuasiGrad.U_su_xfm(
        [zeros(sys.nx) for tii in prm.ts.time_keys],
        [zeros(sys.nx) for tii in prm.ts.time_keys])
    
    u_sd_xfm = QuasiGrad.U_sd_xfm(
        [zeros(sys.nl) for tii in prm.ts.time_keys],
        [zeros(sys.nl) for tii in prm.ts.time_keys])

    # these two following elements are unique -- they serve to collect all of the 
    # coefficients applied to the same partial derivatives (e.g.,
    # a1*dxdp, a2*dxdp, a3*dxdp => dxdp[tii][dev] = a1+a2+a3)
    dx = QuasiGrad.Dx(
        [zeros(sys.ndev) for tii in prm.ts.time_keys],
        [zeros(sys.ndev) for tii in prm.ts.time_keys])

    # now, assemble the full grd struct
    grd = QuasiGrad.Grad(
        acline_pfr,
        acline_qfr,
        acline_pto,
        acline_qto,
        zs_acline,
        xfm_pfr,
        xfm_qfr,
        xfm_pto,
        xfm_qto,
        zs_xfm,
        sh_p,
        sh_q,
        zp,
        zq,
        zen_dev,
        u_su_dev,
        u_sd_dev,
        u_su_acline,
        u_sd_acline,
        u_su_xfm,
        u_sd_xfm,
        dx)

    # output
    return grd
end

# perturb, clip, and fix states
function perturb_states!(pert_size::Float64, prm::QuasiGrad.Param, stt::QuasiGrad.State, sys::QuasiGrad.System)
    # perturb all states
    for tii in prm.ts.time_keys
        stt.u_on_acline[tii]  = ones(sys.nl)
        stt.u_on_xfm[tii]     = ones(sys.nx)
        stt.u_on_dev[tii]     = Int64.(rand(Bool, sys.ndev))
        stt.vm[tii]           = pert_size*0.1*randn(sys.nb) .+ 1.0
        stt.va[tii]           = pert_size*0.1*randn(sys.nb)
        stt.tau[tii]          = pert_size*0.1*randn(sys.nx) .+ 1.0
        stt.phi[tii]          = pert_size*0.1*randn(sys.nx)        
        stt.dc_pfr[tii]       = pert_size*0.1*rand(sys.nldc)    
        stt.dc_qfr[tii]       = pert_size*0.1*rand(sys.nldc)       
        stt.dc_qto[tii]       = pert_size*0.1*rand(sys.nldc)  
        stt.u_step_shunt[tii] = pert_size*4.0*rand(sys.nsh) # bigger spread
        stt.p_on[tii]         = pert_size*rand(sys.ndev)    
        stt.dev_q[tii]        = pert_size*rand(sys.ndev)  
        stt.p_rgu[tii]        = pert_size*rand(sys.ndev) 
        stt.p_rgd[tii]        = pert_size*rand(sys.ndev)   
        stt.p_scr[tii]        = pert_size*rand(sys.ndev)      
        stt.p_nsc[tii]        = pert_size*rand(sys.ndev)    
        stt.p_rru_on[tii]     = pert_size*rand(sys.ndev)      
        stt.p_rrd_on[tii]     = pert_size*rand(sys.ndev)      
        stt.p_rru_off[tii]    = pert_size*rand(sys.ndev)  
        stt.p_rrd_off[tii]    = pert_size*rand(sys.ndev)     
        stt.q_qru[tii]        = pert_size*rand(sys.ndev)    
        stt.q_qrd[tii]        = pert_size*rand(sys.ndev) 
    end
end

function build_constant_gradient(idx::QuasiGrad.Index, prm::QuasiGrad.Param, qG::QuasiGrad.QG, sys::QuasiGrad.System)
    # build a structure which hold constant gradient information
    # 
    # how many ctg states do we need?
    num_wrst = Int64(ceil(qG.frac_ctg_keep*sys.nctg/2))  # in case n_ctg is odd, and we want to keep all!
    num_rnd  = Int64(floor(qG.frac_ctg_keep*sys.nctg/2)) # in case n_ctg is odd, and we want to keep all!
    num_ctg  = num_wrst + num_rnd

    # contingency costs
    if num_ctg < sys.nctg
        @info "Note: scaling average contingency violation grads via $num_ctg instead of $(sys.nctg)."
    end
    ctg_avg = [prm.ts.duration[tii]*prm.vio.s_flow/num_ctg for tii in prm.ts.time_keys]
    ctg_min = [prm.ts.duration[tii]*prm.vio.s_flow         for tii in prm.ts.time_keys]

    # device on costs
    dzon_dev_du_on_dev = [prm.ts.duration[tii]*prm.dev.on_cost for tii in prm.ts.time_keys]

    # device energy costs
    dzt_dzen              = zeros(sys.ndev)
    dzt_dzen[idx.cs_devs] = +ones(sys.ncs)
    dzt_dzen[idx.pr_devs] = -ones(sys.npr)

    # device reserve gradients
    dzrgu_dp_rgu     = [prm.ts.duration[tii]*getindex.(prm.dev.p_reg_res_up_cost,tii)            for tii in prm.ts.time_keys]
    dzrgd_dp_rgd     = [prm.ts.duration[tii]*getindex.(prm.dev.p_reg_res_down_cost,tii)          for tii in prm.ts.time_keys]
    dzscr_dp_scr     = [prm.ts.duration[tii]*getindex.(prm.dev.p_syn_res_cost,tii)               for tii in prm.ts.time_keys]
    dznsc_dp_nsc     = [prm.ts.duration[tii]*getindex.(prm.dev.p_nsyn_res_cost,tii)              for tii in prm.ts.time_keys]
    dzrru_dp_rru_on  = [prm.ts.duration[tii]*getindex.(prm.dev.p_ramp_res_up_online_cost,tii)    for tii in prm.ts.time_keys]
    dzrru_dp_rru_off = [prm.ts.duration[tii]*getindex.(prm.dev.p_ramp_res_up_offline_cost,tii)   for tii in prm.ts.time_keys]
    dzrrd_dp_rrd_on  = [prm.ts.duration[tii]*getindex.(prm.dev.p_ramp_res_down_online_cost,tii)  for tii in prm.ts.time_keys]
    dzrrd_dp_rrd_off = [prm.ts.duration[tii]*getindex.(prm.dev.p_ramp_res_down_offline_cost,tii) for tii in prm.ts.time_keys]
    dzqru_dq_qru     = [prm.ts.duration[tii]*getindex.(prm.dev.q_res_up_cost,tii)                for tii in prm.ts.time_keys]
    dzqrd_dq_qrd     = [prm.ts.duration[tii]*getindex.(prm.dev.q_res_down_cost,tii)              for tii in prm.ts.time_keys]
    
    # zonal gradients
    dzrgu_zonal_dp_rgu_zonal_penalty = [prm.ts.duration[tii]*prm.vio.rgu_zonal for tii in prm.ts.time_keys]
    dzrgd_zonal_dp_rgd_zonal_penalty = [prm.ts.duration[tii]*prm.vio.rgd_zonal for tii in prm.ts.time_keys]
    dzscr_zonal_dp_scr_zonal_penalty = [prm.ts.duration[tii]*prm.vio.scr_zonal for tii in prm.ts.time_keys]
    dznsc_zonal_dp_nsc_zonal_penalty = [prm.ts.duration[tii]*prm.vio.nsc_zonal for tii in prm.ts.time_keys]
    dzrru_zonal_dp_rru_zonal_penalty = [prm.ts.duration[tii]*prm.vio.rru_zonal for tii in prm.ts.time_keys]
    dzrrd_zonal_dp_rrd_zonal_penalty = [prm.ts.duration[tii]*prm.vio.rrd_zonal for tii in prm.ts.time_keys]
    dzqru_zonal_dq_qru_zonal_penalty = [prm.ts.duration[tii]*prm.vio.qru_zonal for tii in prm.ts.time_keys]
    dzqrd_zonal_dq_qrd_zonal_penalty = [prm.ts.duration[tii]*prm.vio.qrd_zonal for tii in prm.ts.time_keys]
    
    # build the cgd
    cgd = ConstantGrad(
        ctg_avg,
        ctg_min,
        dzon_dev_du_on_dev,
        dzt_dzen,
        dzrgu_dp_rgu,    
        dzrgd_dp_rgd,    
        dzscr_dp_scr,    
        dznsc_dp_nsc,    
        dzrru_dp_rru_on, 
        dzrru_dp_rru_off,
        dzrrd_dp_rrd_on, 
        dzrrd_dp_rrd_off,
        dzqru_dq_qru,    
        dzqrd_dq_qrd,    
        dzrgu_zonal_dp_rgu_zonal_penalty,
        dzrgd_zonal_dp_rgd_zonal_penalty,
        dzscr_zonal_dp_scr_zonal_penalty,
        dznsc_zonal_dp_nsc_zonal_penalty,
        dzrru_zonal_dp_rru_zonal_penalty,
        dzrrd_zonal_dp_rrd_zonal_penalty,
        dzqru_zonal_dq_qru_zonal_penalty,
        dzqrd_zonal_dq_qrd_zonal_penalty)

    # output
    return cgd
end

# manage time
function manage_time!(time_left::Float64, qG::QuasiGrad.QG)
    # how long do the adam iterations have?
    # adam will run length(qG.pcts_to_round) + 1 times
    num_adam_solve   = length(qG.pcts_to_round) + 1
    adam_solve_times = 10 .^(range(1,stop=0.75,length=num_adam_solve))

    # scale to account for 50% of the time -- the rest is for Gurobi
    # and for printing the solution..
    # => we want: alpha*sum(adam_solve_times) = 0.5*time_left
    alpha            = 0.25*time_left/sum(adam_solve_times)
    adam_solve_times = alpha*adam_solve_times

    # update qG
    qG.adam_solve_times = adam_solve_times
end

function build_time_sets(prm::QuasiGrad.Param, sys::QuasiGrad.System)
    # initialize: dev => time => set of time indices
    Ts_mndn     = [[Int8[]                                                 for _ in prm.ts.time_keys] for  _  in 1:sys.ndev]
    Ts_mnup     = [[Int8[]                                                 for _ in prm.ts.time_keys] for  _  in 1:sys.ndev]
    Ts_sdpc     = [[Int8[]                                                 for _ in prm.ts.time_keys] for  _  in 1:sys.ndev]
    ps_sdpc_set = [[Float64[]                                              for _ in prm.ts.time_keys] for  _  in 1:sys.ndev]
    Ts_supc     = [[Int8[]                                                 for _ in prm.ts.time_keys] for  _  in 1:sys.ndev]
    ps_supc_set = [[Float64[]                                              for _ in prm.ts.time_keys] for  _  in 1:sys.ndev]
    Ts_sus_jft  = [[[Int8[] for _ in 1:prm.dev.num_sus[dev]]               for _ in prm.ts.time_keys] for dev in 1:sys.ndev]
    Ts_sus_jf   = [[[Int8[] for _ in 1:prm.dev.num_sus[dev]]               for _ in prm.ts.time_keys] for dev in 1:sys.ndev]
    Ts_en_max   = [[Int8[]  for _ in 1:length(prm.dev.energy_req_ub[dev])]                            for dev in 1:sys.ndev]
    Ts_en_min   = [[Int8[]  for _ in 1:length(prm.dev.energy_req_lb[dev])]                            for dev in 1:sys.ndev]
    Ts_su_max   = [[Int8[]  for _ in 1:length(prm.dev.startups_ub[dev])]                              for dev in 1:sys.ndev]

    # loop over devices
    for dev in prm.dev.dev_keys

        # loop over time
        for tii in prm.ts.time_keys
            # up and down times
            Ts_mndn[dev][tii] = get_tmindn(tii, dev, prm)
            Ts_mnup[dev][tii] = get_tminup(tii, dev, prm)

            # startup/down power curves
            Ts_sdpc[dev][tii], ps_sdpc_set[dev][tii] = get_sdpc(tii, dev, prm)
            Ts_supc[dev][tii], ps_supc_set[dev][tii] = get_supc(tii, dev, prm)

            # loop over sus (i.e., f in F)
            for ii in 1:prm.dev.num_sus[dev]
                Ts_sus_jft[dev][tii][ii], Ts_sus_jf[dev][tii][ii] = get_tsus_sets(tii, dev, prm, ii)
            end
        end

        # => Wub = prm.dev.energy_req_ub[dev]
        # => Wlb = prm.dev.energy_req_lb[dev]
        # max energy
        for (w_ind, w_params) in enumerate(prm.dev.energy_req_ub[dev])
            Ts_en_max[dev][w_ind] = get_tenmax(w_params, prm)
        end

        # min energy
        for (w_ind, w_params) in enumerate(prm.dev.energy_req_lb[dev])
            Ts_en_min[dev][w_ind] = get_tenmin(w_params, prm)
        end

        # max start ups
        for (w_ind, w_params) in enumerate(prm.dev.startups_ub[dev])
            Ts_su_max[dev][w_ind] = get_tsumax(w_params, prm)
        end
    end

    # output
    return Ts_mndn, Ts_mnup, Ts_sdpc, ps_sdpc_set, Ts_supc, ps_supc_set, 
           Ts_sus_jft, Ts_sus_jf, Ts_en_max, Ts_en_min, Ts_su_max
end

function initialize_lbfgs(mgd::QuasiGrad.MasterGrad, prm::QuasiGrad.Param, qG::QuasiGrad.QG, stt::QuasiGrad.State, sys::QuasiGrad.System, upd::Dict{Symbol, Vector{Vector{Int64}}})
    # define the mapping indices which put gradient and state
    # information into aggregated forms -- to be populated!

    # shall we define the mapping based on time?
    if qG.lbfgs_map_over_all_time == true
        # in this case, include all time indices -- not generally needed
        map = Dict(
            :vm            => Dict(tii => Int64[] for tii in prm.ts.time_keys),       
            :va            => Dict(tii => Int64[] for tii in prm.ts.time_keys),           
            :tau           => Dict(tii => Int64[] for tii in prm.ts.time_keys),            
            :phi           => Dict(tii => Int64[] for tii in prm.ts.time_keys), 
            :dc_pfr        => Dict(tii => Int64[] for tii in prm.ts.time_keys), 
            :dc_qfr        => Dict(tii => Int64[] for tii in prm.ts.time_keys), 
            :dc_qto        => Dict(tii => Int64[] for tii in prm.ts.time_keys),  
            :u_step_shunt  => Dict(tii => Int64[] for tii in prm.ts.time_keys),
            :p_on          => Dict(tii => Int64[] for tii in prm.ts.time_keys), 
            :dev_q         => Dict(tii => Int64[] for tii in prm.ts.time_keys))

        # next, how many lbfgs states are there at each time? let's base this on "upd"
        n_lbfgs = zeros(Int64, sys.nT)
        for var_key in [:vm, :va, :tau, :phi, :dc_pfr, :dc_qfr, :dc_qto, :u_step_shunt, :p_on, :dev_q]
            for tii in prm.ts.time_keys
                if var_key in keys(upd)
                    n = length(upd[var_key][tii]) # number
                    if n == 0
                        map[var_key][tii] = Int64[]
                    else
                        # this is fine, because we will grab "1:n" of the update variables,
                        # i.e., all of them, later on
                        map[var_key][tii] = collect(1:n) .+ n_lbfgs[tii]
                    end

                    # update the total number
                    n_lbfgs[tii] += n
                else
                    n = length(mgd[var_key][tii])
                    if n == 0
                        map[var_key][tii] = Int64[]
                    else
                        map[var_key][tii] = collect(1:n) .+ n_lbfgs[tii]
                    end

                    # update the total number
                    n_lbfgs[tii] += n
                end
            end
        end
    else
        # mappings are NOT a function of time
        map = Dict(
            :vm            => Int64[],       
            :va            => Int64[],           
            :tau           => Int64[],            
            :phi           => Int64[], 
            :dc_pfr        => Int64[], 
            :dc_qfr        => Int64[], 
            :dc_qto        => Int64[],  
            :u_step_shunt  => Int64[],
            :p_on          => Int64[], 
            :dev_q         => Int64[])

        # next, how many lbfgs states are there at each time? let's base this on "upd"
        n_lbfgs = 0
        tii     = 1
        for var_key in [:vm, :va, :tau, :phi, :dc_pfr, :dc_qfr, :dc_qto, :u_step_shunt, :p_on, :dev_q]
            if var_key in keys(upd)
                n = length(upd[var_key][tii]) # number
                if n == 0
                    map[var_key] = Int64[]
                else
                    map[var_key] = collect(1:n) .+ n_lbfgs
                end

                # update the total number
                n_lbfgs += n
            else
                n = length(getfield(mgd,var_key)[tii])
                if n == 0
                    map[var_key] = Int64[]
                else
                    map[var_key] = collect(1:n) .+ n_lbfgs
                end

                # update the total number
                n_lbfgs += n
            end
        end
    end

    # build the lbfgs dict
    state = Dict(:x_now      => Dict(tii => zeros(n_lbfgs)           for tii in prm.ts.time_keys),
                 :x_new      => Dict(tii => zeros(n_lbfgs)           for tii in prm.ts.time_keys),
                 :x_prev     => Dict(tii => zeros(n_lbfgs)           for tii in prm.ts.time_keys),
                 :gradf_now  => Dict(tii => zeros(n_lbfgs)           for tii in prm.ts.time_keys),
                 :gradf_prev => Dict(tii => zeros(n_lbfgs)           for tii in prm.ts.time_keys),
                 :q          => Dict(tii => zeros(n_lbfgs)           for tii in prm.ts.time_keys),
                 :r          => Dict(tii => zeros(n_lbfgs)           for tii in prm.ts.time_keys),
                 :alpha      => Dict(tii => zeros(qG.num_lbfgs_to_keep) for tii in prm.ts.time_keys),
                 :rho        => Dict(tii => zeros(qG.num_lbfgs_to_keep) for tii in prm.ts.time_keys))

    # build the lbfgs difference dict
    diff = Dict(:s => Dict(tii => [zeros(n_lbfgs) for _ in 1:qG.num_lbfgs_to_keep] for tii in prm.ts.time_keys),
                :y => Dict(tii => [zeros(n_lbfgs) for _ in 1:qG.num_lbfgs_to_keep] for tii in prm.ts.time_keys))

    # step size control -- for adam!
    step = Dict(:zpf_prev    => Dict(tii => 0.0    for tii in prm.ts.time_keys),
                :beta1_decay => Dict(tii => 1.0    for tii in prm.ts.time_keys),
                :beta2_decay => Dict(tii => 1.0    for tii in prm.ts.time_keys),
                :m           => Dict(tii => 0.0    for tii in prm.ts.time_keys),   
                :v           => Dict(tii => 0.0    for tii in prm.ts.time_keys),   
                :mhat        => Dict(tii => 0.0    for tii in prm.ts.time_keys),
                :vhat        => Dict(tii => 0.0    for tii in prm.ts.time_keys),
                :step        => Dict(tii => 0.0    for tii in prm.ts.time_keys),
                :alpha_0     => Dict(tii => qG.lbfgs_adam_alpha_0 for tii in prm.ts.time_keys))

    # indices to track where previous differential vectors are stored --
    # lbfgs_idx[1] is always the most recent data, and lbfgs_idx[end] is the oldest
    idx = Int64.(zeros(qG.num_lbfgs_to_keep))

    # create a scoring dict
    zpf = Dict(
        :zp  => Dict(tii => 0.0 for tii in prm.ts.time_keys),
        :zq  => Dict(tii => 0.0 for tii in prm.ts.time_keys),
        :zs  => Dict(tii => 0.0 for tii in prm.ts.time_keys))

    # create the dict for regularizing the solution
    p0 = Dict(
        :p_on => Dict(tii => copy(stt.p_on[tii]) for tii in prm.ts.time_keys))

    # build the lbfgs struct
    lbfgs = QuasiGrad.LBFGS(p0, state, diff, idx, map, step, zpf)

    return lbfgs
end