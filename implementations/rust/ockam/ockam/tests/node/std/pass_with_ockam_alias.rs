#![deny(unused_imports)]

use ockam::{self as o};

#[ockam::node]
async fn main(mut c: o::Context) {
    c.stop().await.unwrap();
}
