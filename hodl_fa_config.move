module spike_fun::hodl_fa_config {
    use std::signer;
    use std::error;
    use std::option::{Self, Option};
    use std::string::{Self, String};
    use supra_framework::account;

    use aptos_std::event::{Self, EventHandle};

    const ERR_NO_PERMISSIONS: u64 = 200;
    const ERR_NOT_INITIALIZED: u64 = 201;
    const ERR_GLOBAL_EMERGENCY: u64 = 202;
    const ERR_INVALID_CONFIG_VALUE: u64 = 203;
    const ERR_CANNOT_TRANSFER_TO_SELF: u64 = 204;
    const ERR_NO_PENDING_ADMIN_TRANSFER: u64 = 205;
    const ERR_NOT_THE_PENDING_ADMIN: u64 = 206;

    const MIN_TREASURY_GRACE_PERIOD_SECONDS: u64 = 7 * 24 * 60 * 60;
    const MAX_TREASURY_GRACE_PERIOD_SECONDS: u64 = 365 * 24 * 60 * 60; 

    struct GlobalConfig has key {
        emergency_admin_address: address,
        treasury_admin_address: address,
        fee_treasury_address: address,
        global_emergency_locked: bool,
        treasury_withdraw_grace_period_seconds: u64,
        pool_registration_fee_amount: u64,
        linked_contract_address: Option<address>,
    }

    struct AdminConfig has key {
        current_admin: address,
        pending_admin_candidate: Option<address>,
    }
    
    struct ConfigParameterUpdatedEvent has drop, store {
        admin_address: address,
        parameter_name: String,
        new_value_u64: u64,
        new_value_address: Option<address>,
    }

    struct AdminProposedEvent has drop, store {
        old_admin: address,
        new_admin_candidate: address,
    }

    struct AdminTransferredEvent has drop, store {
        old_admin: address,
        new_admin: address,
    }

    struct EventHandles has key {
        config_parameter_updated_events: EventHandle<ConfigParameterUpdatedEvent>,
        admin_proposed_events: EventHandle<AdminProposedEvent>,
        admin_transferred_events: EventHandle<AdminTransferredEvent>,
    }

    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @spike_fun, error::permission_denied(ERR_NO_PERMISSIONS));
        
        move_to(admin, GlobalConfig {
            emergency_admin_address: admin_addr,
            treasury_admin_address: admin_addr,
            fee_treasury_address: admin_addr,
            global_emergency_locked: false,
            treasury_withdraw_grace_period_seconds: 7257600,
            pool_registration_fee_amount: 137_000_000,
            linked_contract_address: option::none(),
        });

        move_to(admin, AdminConfig {
            current_admin: admin_addr,
            pending_admin_candidate: option::none(),
        });
        
        move_to(admin, EventHandles {
            config_parameter_updated_events: account::new_event_handle<ConfigParameterUpdatedEvent>(admin),
            admin_proposed_events: account::new_event_handle<AdminProposedEvent>(admin),
            admin_transferred_events: account::new_event_handle<AdminTransferredEvent>(admin),
        });
    }


    public entry fun set_emergency_admin_address(admin: &signer, new_address: address) acquires GlobalConfig, AdminConfig {
        assert_is_current_admin(admin);
        let global_config = borrow_global_mut<GlobalConfig>(@spike_fun);
        global_config.emergency_admin_address = new_address;
    }

    public entry fun set_treasury_admin_address(admin: &signer, new_address: address) acquires GlobalConfig, AdminConfig {
        assert_is_current_admin(admin);
        let global_config = borrow_global_mut<GlobalConfig>(@spike_fun);
        global_config.treasury_admin_address = new_address;
    }
    
    public entry fun set_treasury_withdraw_grace_period(
        admin_signer: &signer,
        new_period: u64
    ) acquires GlobalConfig, EventHandles, AdminConfig {
        assert_is_current_admin(admin_signer);
        assert!(
            new_period >= MIN_TREASURY_GRACE_PERIOD_SECONDS && new_period <= MAX_TREASURY_GRACE_PERIOD_SECONDS,
            error::invalid_argument(ERR_INVALID_CONFIG_VALUE) 
        );

        let config = borrow_global_mut<GlobalConfig>(@spike_fun);
        config.treasury_withdraw_grace_period_seconds = new_period;

        let event_handles = borrow_global_mut<EventHandles>(@spike_fun);
        event::emit_event<ConfigParameterUpdatedEvent>(
            &mut event_handles.config_parameter_updated_events,
            ConfigParameterUpdatedEvent {
                admin_address: signer::address_of(admin_signer),
                parameter_name: string::utf8(b"treasury_withdraw_grace_period_seconds"),
                new_value_u64: new_period,
                new_value_address: option::none(),
             }
        );
    }

    public entry fun set_pool_registration_fee(
        admin_signer: &signer,
        new_fee_amount: u64,
        new_fee_treasury_address: address
    ) acquires GlobalConfig, EventHandles, AdminConfig {
        assert_is_current_admin(admin_signer);

        let config = borrow_global_mut<GlobalConfig>(@spike_fun);
        config.pool_registration_fee_amount = new_fee_amount;
        config.fee_treasury_address = new_fee_treasury_address;

        let event_handles = borrow_global_mut<EventHandles>(@spike_fun);
        event::emit_event<ConfigParameterUpdatedEvent>(
            &mut event_handles.config_parameter_updated_events,
            ConfigParameterUpdatedEvent  {
                admin_address: signer::address_of(admin_signer),
                parameter_name: string::utf8(b"pool_registration_fee"),
                new_value_u64: new_fee_amount,
                new_value_address: option::some(new_fee_treasury_address),
            }
        );
    }

    public entry fun set_linked_contract_address(
        admin_signer: &signer,
        whitelisted_addr: address
    ) acquires GlobalConfig, EventHandles, AdminConfig {
        assert_is_current_admin(admin_signer);
        assert!(whitelisted_addr != @0x0, error::invalid_argument(ERR_INVALID_CONFIG_VALUE));

        let config = borrow_global_mut<GlobalConfig>(@spike_fun);
        config.linked_contract_address = option::some(whitelisted_addr);

        let event_handles = borrow_global_mut<EventHandles>(@spike_fun);
        event::emit_event<ConfigParameterUpdatedEvent>(
            &mut event_handles.config_parameter_updated_events,
            ConfigParameterUpdatedEvent  {
                admin_address: signer::address_of(admin_signer),
                parameter_name: string::utf8(b"linked_contract_address"),
                new_value_u64: 0,
                new_value_address: option::some(whitelisted_addr),
            }
        );
    }
    
    public entry fun propose_new_admin(
        current_admin_signer: &signer,
        new_candidate_addr: address
    ) acquires AdminConfig, EventHandles {
        assert_is_current_admin(current_admin_signer);

        let admin_config = borrow_global_mut<AdminConfig>(@spike_fun);
        assert!(new_candidate_addr != admin_config.current_admin, error::invalid_argument(ERR_CANNOT_TRANSFER_TO_SELF));
        assert!(new_candidate_addr != @0x0, error::invalid_argument(ERR_INVALID_CONFIG_VALUE));

        let old_admin_val = admin_config.current_admin;
        admin_config.pending_admin_candidate = option::some(new_candidate_addr);
        
        let event_handles = borrow_global_mut<EventHandles>(@spike_fun);
        event::emit_event<AdminProposedEvent>(
            &mut event_handles.admin_proposed_events,
            AdminProposedEvent {
                old_admin: old_admin_val,
                new_admin_candidate: new_candidate_addr,
            }
        );
    }

    public entry fun accept_admin_role(
        candidate_signer: &signer
    ) acquires AdminConfig, EventHandles {
        let candidate_addr = signer::address_of(candidate_signer);
        let admin_config = borrow_global_mut<AdminConfig>(@spike_fun);

        assert!(option::is_some(&admin_config.pending_admin_candidate), error::invalid_state(ERR_NO_PENDING_ADMIN_TRANSFER));
        let pending_admin = *option::borrow(&admin_config.pending_admin_candidate); 
        assert!(candidate_addr == pending_admin, error::permission_denied(ERR_NOT_THE_PENDING_ADMIN));

        let old_admin = admin_config.current_admin;
        admin_config.current_admin = candidate_addr;
        admin_config.pending_admin_candidate = option::none();

        let event_handles = borrow_global_mut<EventHandles>(@spike_fun);
        event::emit_event<AdminTransferredEvent>(
            &mut event_handles.admin_transferred_events,
            AdminTransferredEvent {
                old_admin: old_admin,
                new_admin: candidate_addr,
            }
        );
    }

    public entry fun enable_global_emergency(emergency_admin: &signer) acquires GlobalConfig {
        assert_is_emergency_admin(emergency_admin);
        let global_config = borrow_global_mut<GlobalConfig>(@spike_fun);
        assert!(!global_config.global_emergency_locked, error::invalid_state(ERR_GLOBAL_EMERGENCY));
        global_config.global_emergency_locked = true;
    }

    #[view]
    public fun get_emergency_admin_address(): address acquires GlobalConfig {
        assert!(exists<GlobalConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        borrow_global<GlobalConfig>(@spike_fun).emergency_admin_address
    }

    #[view]
    public fun get_treasury_admin_address(): address acquires GlobalConfig {
        assert!(exists<GlobalConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        borrow_global<GlobalConfig>(@spike_fun).treasury_admin_address
    }
    
    #[view]
    public fun get_treasury_withdraw_grace_period(): u64 acquires GlobalConfig {
        assert!(exists<GlobalConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        borrow_global<GlobalConfig>(@spike_fun).treasury_withdraw_grace_period_seconds
    }

    #[view]
    public fun get_pool_registration_fee_config(): (u64, address) acquires GlobalConfig {
        assert!(exists<GlobalConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        let config = borrow_global<GlobalConfig>(@spike_fun);
        (config.pool_registration_fee_amount, config.fee_treasury_address)
    }
    
    #[view]
    public fun get_linked_contract_address(): Option<address> acquires GlobalConfig {
        assert!(exists<GlobalConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        borrow_global<GlobalConfig>(@spike_fun).linked_contract_address
    }

    #[view]
    public fun is_global_emergency(): bool acquires GlobalConfig {
        assert!(exists<GlobalConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        borrow_global<GlobalConfig>(@spike_fun).global_emergency_locked
    }

    #[view]
    public fun get_current_admin(): address acquires AdminConfig {
        assert!(exists<AdminConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        borrow_global<AdminConfig>(@spike_fun).current_admin
    }

    #[view]
    public fun get_pending_admin_candidate(): Option<address> acquires AdminConfig {
        assert!(exists<AdminConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        let admin_config = borrow_global<AdminConfig>(@spike_fun);
        if (option::is_some(&admin_config.pending_admin_candidate)) {
            option::some(*option::borrow(&admin_config.pending_admin_candidate))
        } else {
            option::none()
        }
    }

    public fun assert_is_current_admin(admin_signer: &signer) acquires AdminConfig {
        assert!(exists<AdminConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        let admin_config = borrow_global<AdminConfig>(@spike_fun);
        assert!(signer::address_of(admin_signer) == admin_config.current_admin, error::permission_denied(ERR_NO_PERMISSIONS));
    }

    public fun assert_is_emergency_admin(admin_signer: &signer) acquires GlobalConfig {
        assert!(exists<GlobalConfig>(@spike_fun), error::invalid_state(ERR_NOT_INITIALIZED));
        let global_config = borrow_global<GlobalConfig>(@spike_fun);
        assert!(signer::address_of(admin_signer) == global_config.emergency_admin_address, error::permission_denied(ERR_NO_PERMISSIONS));
    }
}