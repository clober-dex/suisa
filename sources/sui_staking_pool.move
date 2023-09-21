module suisa::sui_staking_pool {
    use std::vector;
    use std::string::String;

    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID, UID};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::math;
    use sui::clock::Clock;
    use sui::table;

    use sui_system::sui_system::{Self, SuiSystemState};
    use sui_system::staking_pool::{Self, StakedSui, PoolTokenExchangeRate};

    use suisa::stsui::{Self, STSUI};
    use suisa::aquarium::{Self, Aquarium};

    const SuiPerStsuiPrecision: u64 = 1_000_000_000;

    const MIN_STAKING_THRESHOLD: u64 = 1_000_000_000; // 1 SUI

    const EInvalidEpoch: u64 = 0;
    const EInvalidTreasuryCap: u64 = 1;
    const EInsufficientSuiAmount: u64 = 2;

    struct SuiStakingPool has key {
        id: UID,
        stsui_treasury_cap: TreasuryCap<STSUI>,
        published_stsui_amount: u64,
        pending_sui_amount: u64,
        staked_sui_treasury: vector<StakedSui>,
        sui_treasury: Coin<SUI>,
        validator_address: address,
    }

    struct Box has key, store {
        id: UID,
        created_epoch: u64,
        principal: u64,
    }

    // below are public entry functions
    public entry fun create(stsui_treasury_cap: TreasuryCap<STSUI>, validator_address: address, ctx: &mut TxContext) {
        assert!(
            coin::total_supply(&stsui_treasury_cap) == 0,
            EInvalidTreasuryCap
        );
        transfer::share_object(SuiStakingPool {
            id: object::new(ctx),
            stsui_treasury_cap,
            published_stsui_amount: 0,
            pending_sui_amount: 0,
            staked_sui_treasury: vector::empty(),
            sui_treasury: coin::zero(ctx),
            validator_address: validator_address,
        });
    }

    public entry fun stake_and_get_box(sui_system_state: &mut SuiSystemState, sui_staking_pool: &mut SuiStakingPool, stake: Coin<SUI>, ctx: &mut TxContext) {
        // TODO: apply max size limit to staked_sui_treasury
        let stake_sui_amount = coin::value(&stake);
        assert!(stake_sui_amount >= MIN_STAKING_THRESHOLD, EInsufficientSuiAmount);
        let sui_treasury_amount = coin::value(&sui_staking_pool.sui_treasury);
        if (sui_treasury_amount > 0) {
            coin::join(&mut stake, coin::split(&mut sui_staking_pool.sui_treasury, sui_treasury_amount, ctx));
        };
        let staked_sui = sui_system::request_add_stake_non_entry(sui_system_state, stake, sui_staking_pool.validator_address, ctx);
        if (sui_staking_pool.published_stsui_amount + sui_staking_pool.pending_sui_amount > 0) {
            let staked_sui_treasury_size = vector::length(&sui_staking_pool.staked_sui_treasury);
            let last_staked_sui = vector::borrow_mut(&mut sui_staking_pool.staked_sui_treasury, staked_sui_treasury_size - 1);
            if (staking_pool::is_equal_staking_metadata(last_staked_sui, &staked_sui)) {
                staking_pool::join_staked_sui(last_staked_sui, staked_sui);
            } else {
                vector::push_back(&mut sui_staking_pool.staked_sui_treasury, staked_sui);
            };
        } else {
            vector::push_back(&mut sui_staking_pool.staked_sui_treasury, staked_sui);
        };
        sui_staking_pool.pending_sui_amount = sui_staking_pool.pending_sui_amount + stake_sui_amount;
        transfer::public_transfer(Box {
            id: object::new(ctx),
            created_epoch: tx_context::epoch(ctx),
            principal: stake_sui_amount,
        }, tx_context::sender(ctx));
    }

    public entry fun unbox_and_get_stsui(sui_system_state: &mut SuiSystemState, sui_staking_pool: &mut SuiStakingPool, box: Box, ctx: &mut TxContext) {
        let stsui_amount = unbox(sui_system_state, sui_staking_pool, box, ctx);
        stsui::mint(&mut sui_staking_pool.stsui_treasury_cap, stsui_amount, tx_context::sender(ctx), ctx);
    }

    public entry fun unbox_and_get_sui_fish(sui_system_state: &mut SuiSystemState, clock: &Clock, aquarium: &mut Aquarium, sui_staking_pool: &mut SuiStakingPool, box: Box, name: String, ctx: &mut TxContext) {
        let stsui_amount = unbox(sui_system_state, sui_staking_pool, box, ctx);
        let stsui = stsui::mint_and_return_stsui(&mut sui_staking_pool.stsui_treasury_cap, stsui_amount, ctx);
        aquarium::mint(clock, aquarium, stsui, name, ctx);
    }

    public entry fun unstake(sui_system_state: &mut SuiSystemState, sui_staking_pool: &mut SuiStakingPool, stsui: Coin<STSUI>, ctx: &mut TxContext) {
        // TODO: minimize diff between withdrawn amount and sui amount needed
        let current_epoch = tx_context::epoch(ctx);
        let stsui_amount = coin::value(&stsui);
        let sui_amount = stsui_amount * get_sui_per_stsui(sui_system_state, sui_staking_pool, current_epoch) / SuiPerStsuiPrecision;
        let sui_treasury_amount = coin::value(&sui_staking_pool.sui_treasury);
        let result_sui = if (sui_treasury_amount > 0) {
            coin::split(&mut sui_staking_pool.sui_treasury, math::min(sui_treasury_amount, sui_amount), ctx)
        } else {
            coin::zero(ctx)
        };
        let i = 0;
        while (coin::value(&result_sui) < sui_amount) {
            let staked_sui = vector::borrow_mut(&mut sui_staking_pool.staked_sui_treasury, i);
            let sui_amount_needed = math::max(math::min(staking_pool::staked_sui_amount(staked_sui), sui_amount - coin::value(&result_sui)), MIN_STAKING_THRESHOLD);
            let staked_sui_needed = if (staking_pool::staked_sui_amount(staked_sui) - sui_amount_needed >= MIN_STAKING_THRESHOLD) {
                staking_pool::split(staked_sui, sui_amount_needed, ctx)
            } else {
                // TODO: optimize time complexity
                vector::remove(&mut sui_staking_pool.staked_sui_treasury, i)
            };
            let withdrawn_stake = sui_system::request_withdraw_stake_non_entry(sui_system_state, staked_sui_needed, ctx);
            coin::join(&mut result_sui, coin::from_balance(withdrawn_stake, ctx));
            i = i + 1;
        };
        if (coin::value(&result_sui) > sui_amount) {
            let diff_amount = coin::value(&result_sui) - sui_amount;
            let diff = coin::split(&mut result_sui, diff_amount, ctx);
            coin::join(&mut sui_staking_pool.sui_treasury, diff);
        };
        sui_staking_pool.published_stsui_amount = sui_staking_pool.published_stsui_amount - stsui_amount;
        stsui::burn(&mut sui_staking_pool.stsui_treasury_cap, stsui);
        transfer::public_transfer(result_sui, tx_context::sender(ctx));
    }

    // below are private command function
    fun unbox(sui_system_state: &mut SuiSystemState, sui_staking_pool: &mut SuiStakingPool, box: Box, ctx: &mut TxContext): u64 {
        assert!(
            box.created_epoch + 1 <= tx_context::epoch(ctx),
            EInvalidEpoch
        );

        let current_epoch = tx_context::epoch(ctx);
        let Box { id, created_epoch: _, principal } = box;
        object::delete(id);
        let stsui_amount = principal * SuiPerStsuiPrecision / get_sui_per_stsui(sui_system_state, sui_staking_pool, current_epoch);
        sui_staking_pool.pending_sui_amount = sui_staking_pool.pending_sui_amount - principal;
        sui_staking_pool.published_stsui_amount = sui_staking_pool.published_stsui_amount + stsui_amount;
        stsui_amount
    }

    // below are public query functions
    public fun get_sui_per_stsui(sui_system_state: &mut SuiSystemState, sui_staking_pool: &SuiStakingPool, current_epoch: u64): u64 {
        if (sui_staking_pool.published_stsui_amount == 0) {
            return SuiPerStsuiPrecision
        };
        (get_total_sui_amount(sui_system_state, sui_staking_pool, current_epoch) - sui_staking_pool.pending_sui_amount) * SuiPerStsuiPrecision / sui_staking_pool.published_stsui_amount
    }

    public fun get_total_sui_amount(sui_system_state: &mut SuiSystemState, sui_staking_pool: &SuiStakingPool, current_epoch: u64): u64 {
        let total_sui_amount: u64 = coin::value(&sui_staking_pool.sui_treasury);
        let i = 0;
        let staked_sui_treasury_size = vector::length(&sui_staking_pool.staked_sui_treasury);
        while (i < staked_sui_treasury_size) {
            let staked_sui = vector::borrow(&sui_staking_pool.staked_sui_treasury, i);
            total_sui_amount = total_sui_amount + calculate_sui_of_staked_sui(sui_system_state, staked_sui, current_epoch);
            i = i + 1;
        };
        total_sui_amount
    }

    public fun get_total_stsui_amount(sui_staking_pool: &SuiStakingPool): u64 {
        sui_staking_pool.published_stsui_amount
    }

    // below are private query functions
    fun calculate_sui_of_staked_sui(sui_system_state: &mut SuiSystemState, staked_sui: &StakedSui, current_epoch: u64): u64 {
        let staked_amount = staking_pool::staked_sui_amount(staked_sui);
        let pool_id = staking_pool::pool_id(staked_sui);
        let pool_token_withdraw_amount = {
            let exchange_rate_at_staking_epoch = pool_token_exchange_rate_at_epoch(sui_system_state, &pool_id, staking_pool::stake_activation_epoch(staked_sui));
            get_token_amount(&exchange_rate_at_staking_epoch, staked_amount)
        };

        let new_epoch_exchange_rate = pool_token_exchange_rate_at_epoch(sui_system_state, &pool_id, current_epoch);
        let total_sui_withdraw_amount = get_sui_amount(&new_epoch_exchange_rate, pool_token_withdraw_amount);

        let reward_withdraw_amount =
            if (total_sui_withdraw_amount >= staked_amount)
                total_sui_withdraw_amount - staked_amount
            else 0;
        // TODO: let pool_total_rewards_amount = balance::value(&pool.rewards_pool);
        let pool_total_rewards_amount = reward_withdraw_amount;
        reward_withdraw_amount = math::min(reward_withdraw_amount, pool_total_rewards_amount);

        staked_amount + reward_withdraw_amount
    }

    fun pool_token_exchange_rate_at_epoch(
        sui_system_state: &mut SuiSystemState,
        pool_id: &ID,
        epoch: u64,
    ): PoolTokenExchangeRate {
        let pool_token_exchange_rates = sui_system::pool_exchange_rates(sui_system_state, pool_id);
        while (epoch >= 0) {
            if (table::contains(pool_token_exchange_rates, epoch)) {
                return *table::borrow(pool_token_exchange_rates, epoch)
            };
            epoch = epoch - 1;
        };
        // This line really should be unreachable.
        *table::borrow(pool_token_exchange_rates, epoch)
    }

    fun get_token_amount(exchange_rate: &PoolTokenExchangeRate, sui_amount: u64): u64 {
        let exchange_rate_sui_amount = staking_pool::sui_amount(exchange_rate);
        let exchange_rate_pool_token_amount = staking_pool::pool_token_amount(exchange_rate);
        if (exchange_rate_sui_amount == 0 || exchange_rate_pool_token_amount == 0) {
            return sui_amount
        };
        let res = (exchange_rate_pool_token_amount as u128)
                * (sui_amount as u128)
                / (exchange_rate_sui_amount as u128);
        (res as u64)
    }

    fun get_sui_amount(exchange_rate: &PoolTokenExchangeRate, token_amount: u64): u64 {
        let exchange_rate_sui_amount = staking_pool::sui_amount(exchange_rate);
        let exchange_rate_pool_token_amount = staking_pool::pool_token_amount(exchange_rate);
        if (exchange_rate_sui_amount == 0 || exchange_rate_pool_token_amount == 0) {
            return token_amount
        };
        let res = (exchange_rate_sui_amount as u128)
                * (token_amount as u128)
                / (exchange_rate_pool_token_amount as u128);
        (res as u64)
    }
}