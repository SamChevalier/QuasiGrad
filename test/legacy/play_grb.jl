# loop over each device and solve individually -- not clear if this is faster
# than solving one big optimization problem all at once. see legacy code for
# a (n unfinished) version where all devices are solved at once!
model = Model(quasiGrad.Gurobi.Optimizer)

dev = 250

# empty the model!
empty!(model)

# quiet down!!!
quasiGrad.set_optimizer_attribute(model, "OutputFlag", qG.GRB_output_flag)

# set model properties
quasiGrad.set_optimizer_attribute(model, "FeasibilityTol", qG.FeasibilityTol)
quasiGrad.set_optimizer_attribute(model, "MIPGap",         qG.mip_gap)
quasiGrad.set_optimizer_attribute(model, "TimeLimit",      qG.time_lim)

# define local time keys
tkeys = prm.ts.time_keys

# define the minimum set of variables we will need to solve the constraints                                                       -- round() the int?
u_on_dev  = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "u_on_dev_t$(ii)",  start=stt[:u_on_dev][tkeys[ii]][dev],  binary=true)       for ii in 1:(sys.nT))
p_on      = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_on_t$(ii)",      start=stt[:p_on][tkeys[ii]][dev])                         for ii in 1:(sys.nT))
dev_q     = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "dev_q_t$(ii)",     start=stt[:dev_q][tkeys[ii]][dev],     lower_bound = 0.0) for ii in 1:(sys.nT))
p_rgu     = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_rgu_t$(ii)",     start=stt[:p_rgu][tkeys[ii]][dev],     lower_bound = 0.0) for ii in 1:(sys.nT))
p_rgd     = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_rgd_t$(ii)",     start=stt[:p_rgd][tkeys[ii]][dev],     lower_bound = 0.0) for ii in 1:(sys.nT))
p_scr     = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_scr_t$(ii)",     start=stt[:p_scr][tkeys[ii]][dev],     lower_bound = 0.0) for ii in 1:(sys.nT))
p_nsc     = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_nsc_t$(ii)",     start=stt[:p_nsc][tkeys[ii]][dev],     lower_bound = 0.0) for ii in 1:(sys.nT))
p_rru_on  = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_rru_on_t$(ii)",  start=stt[:p_rru_on][tkeys[ii]][dev],  lower_bound = 0.0) for ii in 1:(sys.nT))
p_rru_off = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_rru_off_t$(ii)", start=stt[:p_rru_off][tkeys[ii]][dev], lower_bound = 0.0) for ii in 1:(sys.nT))
p_rrd_on  = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_rrd_on_t$(ii)",  start=stt[:p_rrd_on][tkeys[ii]][dev],  lower_bound = 0.0) for ii in 1:(sys.nT))
p_rrd_off = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "p_rrd_off_t$(ii)", start=stt[:p_rrd_off][tkeys[ii]][dev], lower_bound = 0.0) for ii in 1:(sys.nT))
q_qru     = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "q_qru_t$(ii)",     start=stt[:q_qru][tkeys[ii]][dev],     lower_bound = 0.0) for ii in 1:(sys.nT))
q_qrd     = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "q_qrd_t$(ii)",     start=stt[:q_qrd][tkeys[ii]][dev],     lower_bound = 0.0) for ii in 1:(sys.nT))

# add a few more (implicit) variables which are necessary for solving this system
u_su_dev = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "u_su_dev_t$(ii)", start=stt[:u_su_dev][tkeys[ii]][dev], binary=true) for ii in 1:(sys.nT))
u_sd_dev = Dict{Symbol, quasiGrad.JuMP.VariableRef}(tkeys[ii] => @variable(model, base_name = "u_sd_dev_t$(ii)", start=stt[:u_sd_dev][tkeys[ii]][dev], binary=true) for ii in 1:(sys.nT))

# we have the affine "AffExpr" expressions (whose values are specified)
dev_p = Dict(tkeys[ii] => AffExpr(0.0) for ii in 1:(sys.nT))
p_su  = Dict(tkeys[ii] => AffExpr(0.0) for ii in 1:(sys.nT))
p_sd  = Dict(tkeys[ii] => AffExpr(0.0) for ii in 1:(sys.nT))

# == define active power constraints ==
for (t_ind, tii) in enumerate(prm.ts.time_keys[1:1])
    # first, get the startup power
    T_supc     = idx.Ts_supc[dev][t_ind]     # T_set, p_supc_set = get_supc(tii, dev, prm)
    p_supc_set = idx.ps_supc_set[dev][t_ind] # T_set, p_supc_set = get_supc(tii, dev, prm)
    quasiGrad.add_to_expression!(p_su[tii], sum(p_supc_set[ii]*u_su_dev[tii_inst] for (ii,tii_inst) in enumerate(T_supc); init=0.0))

    # second, get the shutdown power
    T_sdpc     = idx.Ts_sdpc[dev][t_ind]     # T_set, p_sdpc_set = get_sdpc(tii, dev, prm)
    p_sdpc_set = idx.ps_sdpc_set[dev][t_ind] # T_set, p_sdpc_set = get_sdpc(tii, dev, prm)
    quasiGrad.add_to_expression!(p_sd[tii], sum(p_sdpc_set[ii]*u_sd_dev[tii_inst] for (ii,tii_inst) in enumerate(T_sdpc); init=0.0))

    # finally, get the total power balance
    dev_p[tii] = p_on[tii] + p_su[tii] + p_sd[tii]
end

# == define reactive power constraints ==
for (t_ind, tii) in enumerate(prm.ts.time_keys[1:1])
    # only a subset of devices will have a reactive power equality constraint
    if dev in idx.J_pqe

        # the following (pr vs cs) are equivalent
        if dev in idx.pr_devs
            # producer?
            #T_supc = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm)
            #T_sdpc = idx.Ts_sdpc[dev][t_ind] # T_sdpc, ~ = get_sdpc(tii, dev, prm)
            #u_sum  = u_on_dev[tii] + sum(u_su_dev[tii_inst] for tii_inst in T_supc; init=0.0) + sum(u_sd_dev[tii_inst] for tii_inst in T_sdpc; init=0.0)
            #=
            # compute q -- this might be the only equality constraint (and below)
            @constraint(model, dev_q[tii] == prm.dev.q_0[dev]*u_sum + prm.dev.beta[dev]*dev_p[tii])
            =#
        else
            # the device must be a consumer :)
            #T_supc = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm) T_supc     = idx.Ts_supc[dev][t_ind] #T_supc, ~ = get_supc(tii, dev, prm)
            #T_sdpc = idx.Ts_sdpc[dev][t_ind] # T_sdpc, ~ = get_sdpc(tii, dev, prm) T_sdpc, ~ = get_sdpc(tii, dev, prm)
            #u_sum  = u_on_dev[tii] + sum(u_su_dev[tii_inst] for tii_inst in T_supc; init=0.0) + sum(u_sd_dev[tii_inst] for tii_inst in T_sdpc; init=0.0)

            # compute q -- this might be the only equality constraint (and above)
            #=
            @constraint(model, dev_q[tii] == prm.dev.q_0[dev]*u_sum + prm.dev.beta[dev]*dev_p[tii])
            =#
        end
    end
end

# loop over each time period and define the hard constraints
for (t_ind, tii) in enumerate(prm.ts.time_keys[1:1])
    # duration
    dt = prm.ts.duration[tii]
#=
    # 1. Minimum downtime: zhat_mndn
    T_mndn = idx.Ts_mndn[dev][t_ind] # t_set = get_tmindn(tii, dev, prm)
    @constraint(model, u_su_dev[tii] + sum(u_sd_dev[tii_inst] for tii_inst in T_mndn; init=0.0) - 1.0 <= 0)

    # 2. Minimum uptime: zhat_mnup
    T_mnup = idx.Ts_mnup[dev][t_ind] # t_set = get_tminup(tii, dev, prm)
    @constraint(model, u_sd_dev[tii] + sum(u_su_dev[tii_inst] for tii_inst in T_mnup; init=0.0) - 1.0 <= 0)

    =#
    # define the previous power value (used by both up and down ramping!)
    if tii == :t1
        # note: p0 = prm.dev.init_p[dev]
        dev_p_previous = prm.dev.init_p[dev]
    else
        # grab previous time
        tii_m1 = prm.ts.time_keys[t_ind-1]
        dev_p_previous = dev_p[tii_m1]
    end

    
    # 3. Ramping limits (up): zhat_rup
    #=
    @constraint(model, dev_p[tii] - dev_p_previous
            - dt*(prm.dev.p_ramp_up_ub[dev]     *(u_on_dev[tii] - u_su_dev[tii])
            +     prm.dev.p_startup_ramp_ub[dev]*(u_su_dev[tii] + 1.0 - u_on_dev[tii])) <= 0)
=#
    # 4. Ramping limits (down): zhat_rd
    @constraint(model,  dev_p_previous - dev_p[tii]
            - dt*(prm.dev.p_ramp_down_ub[dev]*u_on_dev[tii]
            +     prm.dev.p_shutdown_ramp_ub[dev]*(1.0-u_on_dev[tii])) <= 0)
   #=
    # 5. Regulation up: zhat_rgu
    @constraint(model, p_rgu[tii] - prm.dev.p_reg_res_up_ub[dev]*u_on_dev[tii] <= 0)
    
    # 6. Regulation down: zhat_rgd
    @constraint(model, p_rgd[tii] - prm.dev.p_reg_res_down_ub[dev]*u_on_dev[tii] <= 0)

    # 7. Synchronized reserve: zhat_scr
    @constraint(model, p_rgu[tii] + p_scr[tii] - prm.dev.p_syn_res_ub[dev]*u_on_dev[tii] <= 0)
    
    # 8. Synchronized reserve: zhat_nsc
    @constraint(model, p_nsc[tii] - prm.dev.p_nsyn_res_ub[dev]*(1.0 - u_on_dev[tii]) <= 0)
    
    # 9. Ramping reserve up (on): zhat_rruon
    @constraint(model, p_rgu[tii] + p_scr[tii] + p_rru_on[tii] - prm.dev.p_ramp_res_up_online_ub[dev]*u_on_dev[tii] <= 0)

    # 10. Ramping reserve up (off): zhat_rruoff
    @constraint(model, p_nsc[tii] + p_rru_off[tii] - prm.dev.p_ramp_res_up_offline_ub[dev]*(1.0-u_on_dev[tii]) <= 0)
    
    # 11. Ramping reserve down (on): zhat_rrdon
    @constraint(model, p_rgd[tii] + p_rrd_on[tii] - prm.dev.p_ramp_res_down_online_ub[dev]*u_on_dev[tii] <= 0)

    # 12. Ramping reserve down (off): zhat_rrdoff
    @constraint(model, p_rrd_off[tii] - prm.dev.p_ramp_res_down_offline_ub[dev]*(1-u_on_dev[tii]) <= 0)
    =#
    # Now, we must separate: producers vs consumers
    if dev in idx.pr_devs
        #=
        # 13p. Maximum reserve limits (producers): zhat_pmax
        @constraint(model, p_on[tii] + p_rgu[tii] + p_scr[tii] + p_rru_on[tii] - prm.dev.p_ub[dev][t_ind]*u_on_dev[tii] <= 0)
    
        # 14p. Minimum reserve limits (producers): zhat_pmin
        @constraint(model, prm.dev.p_lb[dev][t_ind]*u_on_dev[tii] + p_rrd_on[tii] + p_rgd[tii] - p_on[tii] <= 0)
        
        # 15p. Off reserve limits (producers): zhat_pmaxoff
        @constraint(model, p_su[tii] + p_sd[tii] + p_nsc[tii] + p_rru_off[tii] - prm.dev.p_ub[dev][t_ind]*(1.0 - u_on_dev[tii]) <= 0)

        # get common "u_sum" terms that will be used in the subsequent four equations 
        T_supc = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm) T_supc     = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm)
        T_sdpc = idx.Ts_sdpc[dev][t_ind] # T_sdpc, ~ = get_sdpc(tii, dev, prm) T_sdpc, ~ = get_sdpc(tii, dev, prm)
        u_sum     = u_on_dev[tii] + sum(u_su_dev[tii_inst] for tii_inst in T_supc; init=0.0) + sum(u_sd_dev[tii_inst] for tii_inst in T_sdpc; init=0.0)

        # 16p. Maximum reactive power reserves (producers): zhat_qmax
        @constraint(model, dev_q[tii] + q_qru[tii] - prm.dev.q_ub[dev][t_ind]*u_sum <= 0)

        # 17p. Minimum reactive power reserves (producers): zhat_qmin
        @constraint(model, q_qrd[tii] + prm.dev.q_lb[dev][t_ind]*u_sum - dev_q[tii] <= 0)

        # 18p. Linked maximum reactive power reserves (producers): zhat_qmax_beta
        if dev in idx.J_pqmax
            @constraint(model, dev_q[tii] + q_qru[tii] - prm.dev.q_0_ub[dev]*u_sum
            - prm.dev.beta_ub[dev]*dev_p[tii] <= 0)
        end 
        
        # 19p. Linked minimum reactive power reserves (producers): zhat_qmin_beta
        if dev in idx.J_pqmin
            @constraint(model, prm.dev.q_0_lb[dev]*u_sum
            + prm.dev.beta_lb[dev]*dev_p[tii]
            + q_qrd[tii] - dev_q[tii] <= 0)
        end
    =#
    # consumers
    else  # => dev in idx.cs_devs
    
        # 13c. Maximum reserve limits (consumers): zhat_pmax
        @constraint(model, p_on[tii] + p_rgd[tii] + p_rrd_on[tii] - prm.dev.p_ub[dev][t_ind]*u_on_dev[tii] <= 0)

        # 14c. Minimum reserve limits (consumers): zhat_pmin
        #@constraint(model, prm.dev.p_lb[dev][t_ind]*u_on_dev[tii] + p_rru_on[tii] + p_scr[tii] + p_rgu[tii] - p_on[tii] <= 0)
        
        # 15c. Off reserve limits (consumers): zhat_pmaxoff
        @constraint(model, p_su[tii] + p_sd[tii] + p_rrd_off[tii] - prm.dev.p_ub[dev][t_ind]*(1.0 - u_on_dev[tii]) <= 0)

        # get common "u_sum" terms that will be used in the subsequent four equations 
        #T_supc = idx.Ts_supc[dev][t_ind] # T_supc, ~ = get_supc(tii, dev, prm) T_supc     = idx.Ts_supc[dev][t_ind] #T_supc, ~ = get_supc(tii, dev, prm)
        #T_sdpc = idx.Ts_sdpc[dev][t_ind] # T_sdpc, ~ = get_sdpc(tii, dev, prm) T_sdpc, ~ = get_sdpc(tii, dev, prm)
        #u_sum  = u_on_dev[tii] + sum(u_su_dev[tii_inst] for tii_inst in T_supc; init=0.0) + sum(u_sd_dev[tii_inst] for tii_inst in T_sdpc; init=0.0)

        #=
        # 16c. Maximum reactive power reserves (consumers): zhat_qmax
        @constraint(model, dev_q[tii] + q_qrd[tii] - prm.dev.q_ub[dev][t_ind]*u_sum <= 0)

        # 17c. Minimum reactive power reserves (consumers): zhat_qmin
        @constraint(model, q_qru[tii] + prm.dev.q_lb[dev][t_ind]*u_sum - dev_q[tii] <= 0)
        
        # 18c. Linked maximum reactive power reserves (consumers): zhat_qmax_beta
        if dev in idx.J_pqmax
            @constraint(model, dev_q[tii] + q_qrd[tii] - prm.dev.q_0_ub[dev]*u_sum
            - prm.dev.beta_ub[dev]*dev_p[tii] <= 0)
        end 

        # 19c. Linked minimum reactive power reserves (consumers): zhat_qmin_beta
        if dev in idx.J_pqmin
            @constraint(model, prm.dev.q_0_lb[dev]*u_sum
            + prm.dev.beta_lb[dev]*dev_p[tii]
            + q_qru[tii] - dev_q[tii] <= 0)
        end
        =#
    end

end
#=
# misc penalty: maximum starts over multiple periods
for (w_ind, w_params) in enumerate(prm.dev.startups_ub[dev])
    # get the time periods: zhat_mxst
    T_su_max = idx.Ts_su_max[dev][w_ind] #get_tsumax(w_params, prm)
    @constraint(model, sum(u_su_dev[tii] for tii in T_su_max; init=0.0) - w_params[3] <= 0.0)
end
=#
# now, we need to add two other sorts of constraints:
# 1. "evolutionary" constraints which link startup and shutdown variables
for (t_ind, tii) in enumerate(prm.ts.time_keys[1:1])
    if tii == :t1
        @constraint(model, u_on_dev[tii] - prm.dev.init_on_status[dev] == u_su_dev[tii] - u_sd_dev[tii])
    else
        tii_m1 = prm.ts.time_keys[t_ind-1]
        @constraint(model, u_on_dev[tii] - u_on_dev[tii_m1] == u_su_dev[tii] - u_sd_dev[tii])
    end
    # only one can be nonzero
    @constraint(model, u_su_dev[tii] + u_sd_dev[tii] <= 1)
end

# 2. constraints which hold constant variables from moving
    # a. must run
    # b. planned outages
    # c. pre-defined fixed values (e.g., q_qru = 0 for devs in J_pqe)
    # d. other states which are fixed from previous IBR rounds
    #       note: all of these are relfected in "upd"
# upd = update states
#
# note -- in this loop, we also build the objective function!
# now, let's define an objective function and solve this mf.
# our overall objective is to round and fix some subset of 
# integer variables. Here is our approach: find a feasible
# solution which is as close to our Adam solution as possible.
# next, we process the results: we identify the x% of variables
# which had to move "the least". We fix these values and remove
# their associated indices from upd. the end.
#
# afterwards, we initialize adam with the closest feasible
# solution variable values.
obj = AffExpr(0.0)

for (t_ind, tii) in enumerate(prm.ts.time_keys[1:1])
    # if a device is *not* in the set of variables,
    # then it must be held constant! -- otherwise, try to hold it
    # close to its initial value
    if dev ∉ upd[:u_on_dev][tii]
        @constraint(model, u_on_dev[tii] == stt[:u_on_dev][tii][dev])
    else
        # add it to the objective function
        tmp = @variable(model)
        @constraint(model, u_on_dev[tii]  - stt[:u_on_dev][tii][dev] <= tmp)
        @constraint(model, stt[:u_on_dev][tii][dev] - u_on_dev[tii]  <= tmp)
        quasiGrad.add_to_expression!(obj, tmp, qG.binary_projection_weight)
    end

    if dev ∉ upd[:p_rrd_off][tii]
        @constraint(model, p_rrd_off[tii] == stt[:p_rrd_off][tii][dev])
    else
        # add it to the objective function
        tmp = @variable(model)
        @constraint(model, p_rrd_off[tii] - stt[:p_rrd_off][tii][dev] <= tmp)
        @constraint(model, stt[:p_rrd_off][tii][dev] - p_rrd_off[tii] <= tmp)
        quasiGrad.add_to_expression!(obj, tmp)
    end

    if dev ∉ upd[:p_nsc][tii]
        @constraint(model, p_nsc[tii] == stt[:p_nsc][tii][dev])
    else
        # add it to the objective function
        tmp = @variable(model)
        @constraint(model, p_nsc[tii]  - stt[:p_nsc][tii][dev] <= tmp)
        @constraint(model, stt[:p_nsc][tii][dev] - p_nsc[tii] <= tmp)
        quasiGrad.add_to_expression!(obj, tmp)
    end

    if dev ∉ upd[:p_rru_off][tii]
        @constraint(model, p_rru_off[tii] == stt[:p_rru_off][tii][dev])
    else
        # add it to the objective function
        tmp = @variable(model)
        @constraint(model, p_rru_off[tii]  - stt[:p_rru_off][tii][dev] <= tmp)
        @constraint(model, stt[:p_rru_off][tii][dev] - p_rru_off[tii]  <= tmp)
        quasiGrad.add_to_expression!(obj, tmp)
    end

    if dev ∉ upd[:q_qru][tii]
        @constraint(model, q_qru[tii] == stt[:q_qru][tii][dev])
    else
        # add it to the objective function
        tmp = @variable(model)
        @constraint(model, q_qru[tii]  - stt[:q_qru][tii][dev] <= tmp)
        @constraint(model, stt[:q_qru][tii][dev] - q_qru[tii]  <= tmp)
        quasiGrad.add_to_expression!(obj, tmp)
    end
    if dev ∉ upd[:q_qrd][tii]
        @constraint(model, q_qrd[tii] == stt[:q_qrd][tii][dev])
    else
        # add it to the objective function
        tmp = @variable(model)
        @constraint(model, q_qrd[tii]  - stt[:q_qrd][tii][dev] <= tmp)
        @constraint(model, stt[:q_qrd][tii][dev] - q_qrd[tii]  <= tmp)
        quasiGrad.add_to_expression!(obj, tmp)
    end

    # now, deal with reactive powers, some of which are specified with equality
    # only a subset of devices will have a reactive power equality constraint
    if dev ∉ idx.J_pqe

        # add it to the objective function
        tmp = @variable(model)
        @constraint(model, dev_q[tii]  - stt[:dev_q][tii][dev] <= tmp)
        @constraint(model, stt[:dev_q][tii][dev] - dev_q[tii]  <= tmp)
        quasiGrad.add_to_expression!(obj, tmp)
    end

    # and now the rest -- none of which are in fixed sets
    #
    # p_on
    tmp = @variable(model)
    @constraint(model, p_on[tii]  - stt[:p_on][tii][dev] <= tmp)
    @constraint(model, stt[:p_on][tii][dev] - p_on[tii]  <= tmp)
    quasiGrad.add_to_expression!(obj, tmp)
    
    # p_rgu 
    tmp = @variable(model)
    @constraint(model, p_rgu[tii]  - stt[:p_rgu][tii][dev] <= tmp)
    @constraint(model, stt[:p_rgu][tii][dev] - p_rgu[tii]  <= tmp)
    quasiGrad.add_to_expression!(obj, tmp)
    
    # p_rgd
    tmp = @variable(model)
    @constraint(model, p_rgd[tii]  - stt[:p_rgd][tii][dev] <= tmp)
    @constraint(model, stt[:p_rgd][tii][dev] - p_rgd[tii]  <= tmp)
    quasiGrad.add_to_expression!(obj, tmp)

    # p_scr
    tmp = @variable(model)
    @constraint(model, p_scr[tii]  - stt[:p_scr][tii][dev] <= tmp)
    @constraint(model, stt[:p_scr][tii][dev] - p_scr[tii]  <= tmp)
    quasiGrad.add_to_expression!(obj, tmp)

    # p_rru_on
    tmp = @variable(model)
    @constraint(model, p_rru_on[tii]  - stt[:p_rru_on][tii][dev] <= tmp)
    @constraint(model, stt[:p_rru_on][tii][dev] - p_rru_on[tii]  <= tmp)
    quasiGrad.add_to_expression!(obj, tmp)

    # p_rrd_on
    tmp = @variable(model)
    @constraint(model, p_rrd_on[tii]  - stt[:p_rrd_on][tii][dev] <= tmp)
    @constraint(model, stt[:p_rrd_on][tii][dev] - p_rrd_on[tii]  <= tmp)
    quasiGrad.add_to_expression!(obj, tmp)
end

# set the objective
@objective(model, Min, obj)

# solve
quasiGrad.optimize!(model)
println("========================================================")
println(quasiGrad.termination_status(model),". ",quasiGrad.primal_status(model),". objective value: ", quasiGrad.objective_value(model))
println("========================================================")

# solve, and then return the solution
#=
for tii in prm.ts.time_keys
    GRB[:u_on_dev][tii][dev]  = quasiGrad.value(u_on_dev[tii])
    GRB[:p_on][tii][dev]      = quasiGrad.value(p_on[tii])
    GRB[:dev_q][tii][dev]     = quasiGrad.value(dev_q[tii])
    GRB[:p_rgu][tii][dev]     = quasiGrad.value(p_rgu[tii])
    GRB[:p_rgd][tii][dev]     = quasiGrad.value(p_rgd[tii])
    GRB[:p_scr][tii][dev]     = quasiGrad.value(p_scr[tii])
    GRB[:p_nsc][tii][dev]     = quasiGrad.value(p_nsc[tii])
    GRB[:p_rru_on][tii][dev]  = quasiGrad.value(p_rru_on[tii])
    GRB[:p_rru_off][tii][dev] = quasiGrad.value(p_rru_off[tii])
    GRB[:p_rrd_on][tii][dev]  = quasiGrad.value(p_rrd_on[tii])
    GRB[:p_rrd_off][tii][dev] = quasiGrad.value(p_rrd_off[tii])
    GRB[:q_qru][tii][dev]     = quasiGrad.value(q_qru[tii])
    GRB[:q_qrd][tii][dev]     = quasiGrad.value(q_qrd[tii])
end
=#

# %% ==========
for (t_ind, tii) in enumerate(prm.ts.time_keys[1:1])
    println(quasiGrad.value.(p_su[tii]) + quasiGrad.value.(p_sd[tii]) + quasiGrad.value.(p_rrd_off[tii]) - prm.dev.p_ub[dev][t_ind]*(1.0 - quasiGrad.value.(u_on_dev[tii])))
end