use core::poseidon::poseidon_hash_span;

fn _uniform_random(seed: felt252, max: u128) -> u128 {
    let hash: u256 = poseidon_hash_span(array![seed].span()).into();
    hash.low % max
}

// define the interface
#[dojo::interface]
pub trait IActions {
    fn hit_block(
        ref world: IWorldDispatcher, x: u8, y: u8, z: u8, playerx: u32, playery: u32, playerz: u32
    );
    fn sync_position(ref world: IWorldDispatcher, playerx: u32, playery: u32, playerz: u32);
    fn generate_world(ref world: IWorldDispatcher, z_layer: u8);
    fn sell_all(ref world: IWorldDispatcher);
    fn upgrade_backpack(ref world: IWorldDispatcher);
    fn upgrade_pickaxe(ref world: IWorldDispatcher);
    fn set_username(ref world: IWorldDispatcher, name: felt252);
    fn rebirth(ref world:IWorldDispatcher, nb: u8);
    fn open_egg(ref world:IWorldDispatcher, egg_type: u8);
    fn free_daily_credits(ref world:IWorldDispatcher);
}

// dojo decorator
#[dojo::contract]
pub mod actions {
    use super::{IActions, _uniform_random};
    use starknet::{ContractAddress, get_caller_address};
    use diamond_pit::models::{
        blocks_column::{BlocksColumn, BlocksColumnTrait, MAX_U128},
        player_inventory::{PlayerInventory, PlayerInventoryTrait},
        daily_leaderboard_entry::{DailyLeaderboardEntry},
        player_stats::{PlayerStats, PlayerStatsTrait}, player_position::{PlayerPosition},
        pet_inventory::{PetInventory, PetInventoryTrait}
    };
    use diamond_pit::constants::{REBIRTH_PRICE, ONE_DAY_IN_SECONDS};
    use diamond_pit::helpers::{block::{BlockHelper, BlockType}, math::{fast_power_2}};

    pub mod Errors {
        pub const NOT_ENOUGH_COINS: felt252 = 'not enough coins';
        pub const BLOCK_NOT_FOUND: felt252 = 'block not found';
        pub const NOT_ENOUGH_CREDITS: felt252 = 'not enough credits';
        pub const NOT_AVAILABLE: felt252 = 'not available';
    }

    #[abi(embed_v0)]
    impl ActionsImpl of IActions<ContractState> {
        fn hit_block(
            ref world: IWorldDispatcher,
            x: u8,
            y: u8,
            z: u8,
            playerx: u32,
            playery: u32,
            playerz: u32
        ) {
            let player = get_caller_address();
            let day: u64 = starknet::get_block_info().unbox().block_timestamp / 86400;
            let mut player_leaderboard_entry = get!(world, (player, day), (DailyLeaderboardEntry));
            player_leaderboard_entry.nb_hits += 1;

            let z_layer = z / 10;
            let mut column = get!(world, (x, y, z_layer), (BlocksColumn));
            assert(column.block_exists(z % 10), Errors::BLOCK_NOT_FOUND);

            let (mut player_position, mut inventory) = get!(world, (player), (PlayerPosition, PlayerInventory));
            player_position.x = playerx;
            player_position.y = playery;
            player_position.z = playerz;
            player_position.time = starknet::get_block_info().unbox().block_timestamp;

            // Anti-cheat, can't break blocks that are not accessible
            // if x > 0 && x < 9 && y > 0 && y < 9 {
            //    let mut column1 = get!(world, (x + 1, y, z_layer), (BlocksColumn));
            //    let mut column2 = get!(world, (x - 1, y, z_layer), (BlocksColumn));
            //    let mut column3 = get!(world, (x, y + 1, z_layer), (BlocksColumn));
            //    let mut column4 = get!(world, (x, y - 1, z_layer), (BlocksColumn));

            //    // Avoid being able to
            //    if z % 10 > 0 && z % 10 < 9 && column.block_exists(z % 10 + 1) &&
            //    column.block_exists(z % 10 - 1) &&
            //        column1.block_exists(z % 10) && column2.block_exists(z % 10) &&
            //        column3.block_exists(z % 10) && column4.block_exists(z % 10) {
            //        return;
            //    }
            // }

            let playerStats = get!(world, (player), (PlayerStats));
            let strength = playerStats.get_pickaxe_strength();
            let (new_block, final_hit) = column.hit_block(z % 10, strength);
            let mut inventory_updated = false;
            if final_hit {
                player_leaderboard_entry.nb_blocks_broken += 1;
                let (block_type, _) = BlockHelper::get_block_info(new_block);
                let slots_left = inventory.slots_left(playerStats.get_backpack_max_slots());
                if slots_left >= 1 {
                    inventory.add(BlockHelper::block_u8_to_type(block_type), 1);
                    inventory_updated = true;
                } else { // Send event backpack max capacity reach
                }
            }
            if inventory_updated {
                set!(world, (column, player_leaderboard_entry, player_position, inventory));
            } else {
                set!(world, (column, player_leaderboard_entry, player_position));
            }
        }

        fn sync_position(ref world: IWorldDispatcher, playerx: u32, playery: u32, playerz: u32) {
            let player = get_caller_address();
            let mut player_position = get!(world, (player), (PlayerPosition));
            player_position.x = playerx;
            player_position.y = playery;
            player_position.z = playerz;
            player_position.time = starknet::get_block_info().unbox().block_timestamp;
            set!(world, (player_position));
        }

        fn sell_all(ref world: IWorldDispatcher) {
            let player = get_caller_address();
            let day: u64 = starknet::get_block_info().unbox().block_timestamp / 86400;
            let mut player_leaderboard_entry = get!(world, (player, day), (DailyLeaderboardEntry));

            let (mut inventory, stats) = get!(world, (player), (PlayerInventory, PlayerStats));
            let amount_sold = (inventory.sell_all() * stats.get_rebirth_multiplier().into()) / 100;
            player_leaderboard_entry.nb_coins_collected += amount_sold;
            set!(world, (inventory, player_leaderboard_entry));
        }

        fn upgrade_pickaxe(ref world: IWorldDispatcher) {
            let player = get_caller_address();
            let (mut stats, mut inventory) = get!(world, (player), (PlayerStats, PlayerInventory));
            let next_upgrade_price: u64 = stats.get_pickaxe_next_upgrade_price().into();
            assert(inventory.coins >= next_upgrade_price, Errors::NOT_ENOUGH_COINS);
            inventory.coins -= next_upgrade_price;
            stats.pickaxe_level += 1;
            set!(world, (inventory, stats));
        }

        fn upgrade_backpack(ref world: IWorldDispatcher) {
            let player = get_caller_address();
            let (mut stats, mut inventory) = get!(world, (player), (PlayerStats, PlayerInventory));
            let next_upgrade_price: u64 = stats.get_backpack_next_upgrade_price().into();
            assert(inventory.coins >= next_upgrade_price, Errors::NOT_ENOUGH_COINS);
            inventory.coins -= next_upgrade_price;
            stats.backpack_level += 1;
            set!(world, (inventory, stats));
        }

        fn set_username(ref world: IWorldDispatcher, name: felt252) {
            let player = get_caller_address();
            let mut stats = get!(world, (player), (PlayerStats));
            stats.name = name;
            set!(world, (stats));
        }

        fn rebirth(ref world: IWorldDispatcher, nb: u8) {
            let player = get_caller_address();
            let (mut inventory, mut stats) = get!(world, (player), (PlayerInventory, PlayerStats));
            let rebirth_price = REBIRTH_PRICE * nb.into();
            assert(inventory.coins >= rebirth_price, Errors::NOT_ENOUGH_COINS);
            inventory.coins -= rebirth_price;
            stats.backpack_level = 0;
            stats.pickaxe_level = 0;
            stats.rebirth += nb.into();
            inventory.rebirth_credits += nb.into();
            set!(world, (inventory, stats));
        }

        fn open_egg(ref world:IWorldDispatcher, egg_type: u8) {
            let player = get_caller_address();
            let (position, mut inventory, mut pet_inventory) = get!(world, player, (PlayerPosition, PlayerInventory, PetInventory));
            let timestamp: u64 = starknet::get_block_info().unbox().block_timestamp;
            let rnd_value: u128 = _uniform_random((timestamp + position.x.into() * 100049 + position.z.into() * 5099).into(), 100);

            let mut pet: u8 = 0;
            if egg_type == 0 {
                assert(inventory.rebirth_credits >= 1, Errors::NOT_ENOUGH_CREDITS);
                inventory.rebirth_credits -= 1;
                if rnd_value <= 29 {
                    pet = 1; // voxels.bunny_pet
                } else if rnd_value <= 59 {
                    pet = 2; // voxels.bird_pet
                } else if rnd_value <= 79 {
                    pet = 3; // voxels.ram_pet
                } else if rnd_value <= 98 {
                    pet = 4; // voxels.chicken
                } else if rnd_value == 99 {
                    pet = 5; // voxels.rhino_pet
                } else {
                    pet = 6; // voxels.reptile_pet
                }
            } else if egg_type == 1 {
                assert(inventory.rebirth_credits >= 3, Errors::NOT_ENOUGH_CREDITS);
                inventory.rebirth_credits -= 3;
                if rnd_value <= 24 {
                    pet = 1; // voxels.bunny_pet
                } else if rnd_value <= 49 {
                    pet = 2; // voxels.bird_pet
                } else if rnd_value <= 69 {
                    pet = 3; // voxels.ram_pet
                } else if rnd_value <= 89 {
                    pet = 4; // voxels.chicken
                } else if rnd_value <= 94 {
                    pet = 5; // voxels.rhino_pet
                } else {
                    pet = 6; // voxels.reptile_pet
                }
            } else if egg_type == 2 {
                assert(inventory.rebirth_credits >= 10, Errors::NOT_ENOUGH_CREDITS);
                inventory.rebirth_credits -= 10;
                if rnd_value <= 14 {
                    pet = 1; // voxels.bunny_pet
                } else if rnd_value <= 29 {
                    pet = 2; // voxels.bird_pet
                } else if rnd_value <= 44 {
                    pet = 3; // voxels.ram_pet
                } else if rnd_value <= 59 {
                    pet = 4; // voxels.chicken
                } else if rnd_value <= 79 {
                    pet = 5; // voxels.rhino_pet
                } else {
                    pet = 6; // voxels.reptile_pet
                }
            } else {
                return;
            }

            pet_inventory.add_pet(pet);
            set!(world, (inventory, pet_inventory));
        }

        fn free_daily_credits(ref world:IWorldDispatcher) {
            let player = get_caller_address();
            let timestamp: u64 = starknet::get_block_info().unbox().block_timestamp;
            let (mut stats, mut inventory) = get!(world, player, (PlayerStats, PlayerInventory));
            assert(stats.next_daily_coin <= timestamp, Errors::NOT_AVAILABLE);
            stats.next_daily_coin = timestamp + ONE_DAY_IN_SECONDS;
            inventory.rebirth_credits += 1;
            set!(world, (stats, inventory));
        }

        // Tools
        fn generate_world(ref world: IWorldDispatcher, z_layer: u8) {
            assert(world.is_owner(self.selector().into(), get_caller_address()), 'not owner');

            let timestamp: u64 = starknet::get_block_info().unbox().block_timestamp;

            // Starknet block
            let rnd_value_starknet_block: u128 = _uniform_random(timestamp.into(), 100);
            let starknet_y: u8 = (rnd_value_starknet_block / 10).try_into().unwrap(); // value between 0 and 9
            let starknet_x: u8 = (rnd_value_starknet_block % 10).try_into().unwrap(); // value between 0 and 9

            let mut y: u8 = 0;
            loop {
                if y >= 10 {
                    break;
                }
                let seed_rnd = _uniform_random(
                    timestamp.into() + y.into() * 5099 + z_layer.into(), 10000
                );
                let mut x: u8 = 0;
                loop {
                    if x >= 10 {
                        break;
                    }
                    let mut data: u128 = 42846909754239046452576930880831620; // 10 DeepStone
                    if z_layer > 1 {
                        data = 169440052209945320062463317574197770
                    }; // 10 Deepstone
                    let rnd_value: u128 = (seed_rnd.into() + x.into() * 100049) % 10;
                    let shift = fast_power_2(rnd_value * 12);
                    let mut block: u128 = match z_layer {
                        0 => BlockHelper::new(BlockType::Coal),
                        1 => BlockHelper::new(BlockType::Copper),
                        2 => BlockHelper::new(BlockType::Iron),
                        3 => BlockHelper::new(BlockType::Gold),
                        4 => BlockHelper::new(BlockType::Diamond),
                        _ => BlockHelper::new(BlockType::Coal),
                    }.into();

                    if z_layer == 4 && starknet_x == x && starknet_y == y {
                        block = BlockHelper::new(BlockType::Starknet); // Starknet block instead of diamond
                    }

                    data = (data & (MAX_U128 ^ (4095 * shift))) + block * shift;
                    set!(world, (BlocksColumn { x, y, z_layer, data }));
                    x += 1;
                };
                y += 1;
            };
        }
    }
}
