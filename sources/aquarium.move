module suisa::aquarium {
    use std::vector;
    use std::string::{utf8, String};

    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use sui::ecvrf;
    use sui::package;
    use sui::display;

    use suisa::stsui::STSUI;

    const MinEvolveAvailableAge: u64 = 1000;

    const EIsufficientAge: u64 = 0;
    const EInvalidRandomSeed: u64 = 1;

    struct SuiFish has key, store {
        id: UID,
        stsui_amount: u64,
        name: String,
        type: u64,
        created_at: u64,
        suik_activated: bool,
    }

    struct Aquarium has key {
        id: UID,
        stsui_treasury: Coin<STSUI>,
        public_key: vector<u8>,
    }

    struct ActivateSuikCap has key, store { id: UID }

    struct CreateAquariumCap has key, store { id: UID }

    struct AQUARIUM has drop {}

    // initializer
    fun init(otw: AQUARIUM, ctx: &mut TxContext) {
        transfer::public_transfer(CreateAquariumCap {
            id: object::new(ctx),
        }, tx_context::sender(ctx));

        let keys = vector[
            utf8(b"name"),
            utf8(b"link"),
            utf8(b"image_url"),
            utf8(b"description"),
            utf8(b"project_url"),
            utf8(b"creator"),
        ];

        let values = vector[
            utf8(b"{name}"),
            utf8(b"https://clober.io"),
            utf8(b"https://t4.ftcdn.net/jpg/02/74/20/69/360_F_274206901_Jt1PHZTbtwne17anw5eD9oABxStNJhYT.jpg"),
            utf8(b"A Sui Fish"),
            utf8(b"https://clober.io"),
            utf8(b"Clober Team")
        ];

        let publisher = package::claim(otw, ctx);

        let display = display::new_with_fields<SuiFish>(
            &publisher, keys, values, ctx
        );

        display::update_version(&mut display);

        transfer::public_transfer(publisher, tx_context::sender(ctx));
        transfer::public_transfer(display, tx_context::sender(ctx));

        transfer::public_transfer(ActivateSuikCap {
            id: object::new(ctx),
        }, tx_context::sender(ctx));
    }

    // below are functions for admin of aquarium module
    public entry fun create_aquarium(_cap: &CreateAquariumCap, public_key: vector<u8>, ctx: &mut TxContext) {
        transfer::share_object(Aquarium {
            id: object::new(ctx),
            stsui_treasury: coin::zero(ctx),
            public_key: public_key,
        });
    }

    public entry fun update_public_key(_cap: &CreateAquariumCap, aquarium: &mut Aquarium, public_key: vector<u8>, _ctx: &mut TxContext) {
        aquarium.public_key = public_key;
    }

    // below are public entry functions
    public entry fun mint(clock: &Clock, aquarium: &mut Aquarium, stsui: Coin<STSUI>, name: String, ctx: &mut TxContext) {
        let stsui_amount = coin::value(&stsui);
        coin::join(&mut aquarium.stsui_treasury, stsui);
        transfer::public_transfer(SuiFish {
            id: object::new(ctx),
            stsui_amount: stsui_amount,
            name: name,
            type: 0,
            created_at: clock::timestamp_ms(clock),
            suik_activated: false,
        }, tx_context::sender(ctx));
    }

    public entry fun final_evolve(clock: &Clock, aquarium: &mut Aquarium, sui_fish: &mut SuiFish, output: vector<u8>, proof: vector<u8>, _ctx: &mut TxContext) {
        let age = clock::timestamp_ms(clock) - sui_fish.created_at;
        assert!(age >= MinEvolveAvailableAge, EIsufficientAge);
        assert!(ecvrf::ecvrf_verify(&output, &object::uid_to_bytes(&sui_fish.id), &aquarium.public_key, &proof), EInvalidRandomSeed);
        sui_fish.type = generate_random_type(output);
    }

    public entry fun burn(aquarium: &mut Aquarium, sui_fish: SuiFish, ctx: &mut TxContext) {
        let SuiFish { id, stsui_amount, name: _, type: _, created_at: _, suik_activated: _ } = sui_fish;
        object::delete(id);
        transfer::public_transfer(coin::split(&mut aquarium.stsui_treasury, stsui_amount, ctx), tx_context::sender(ctx));
    }

    // below are public view function
    public fun get_total_stsui_amount(aquarium: &Aquarium): u64 {
        coin::value(&aquarium.stsui_treasury)
    }

    // below are functions for suik module
    public fun activate_suik(_cap: &ActivateSuikCap, sui_fish: &mut SuiFish) {
        sui_fish.suik_activated = true;
    }

    public fun deactivate_suik(_cap: &ActivateSuikCap, sui_fish: &mut SuiFish) {
        sui_fish.suik_activated = false;
    }

    // below are private functions
    fun generate_random_type(seed: vector<u8>): u64 {
        bytes_to_u64(seed) % 100
    }

    fun bytes_to_u64(bytes: vector<u8>): u64 {
        let value: u64 = 0;
        let i: u64 = 0;
        while (i < 8) {
            value = value | ((*vector::borrow(&bytes, i) as u64) << ((8 * (7 - i)) as u8));
            i = i + 1;
        };
        return value
    }
}