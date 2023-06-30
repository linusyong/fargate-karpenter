resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${var.project}-vpc",
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  depends_on = [
    aws_vpc.main
  ]
}

resource "aws_subnet" "public" {
  for_each = toset(data.aws_availability_zones.available.zone_ids)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, substr(each.key, -1, 1) - 1)
  availability_zone = data.aws_availability_zones.available.names[substr(each.key, -1, 1) - 1]

  tags = {
    Name = "${var.project}-public-subnet-${data.aws_availability_zones.available.names[substr(each.key, -1, 1) - 1]}"
  }

  depends_on = [
    aws_vpc.main
  ]
}

resource "aws_subnet" "private" {
  for_each = toset(data.aws_availability_zones.available.zone_ids)

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, var.subnet_cidr_bits, substr(each.key, -1, 1) + 2)
  availability_zone = data.aws_availability_zones.available.names[substr(each.key, -1, 1) - 1]

  tags = {
    Name                                           = "${var.project}-private-subnet-${data.aws_availability_zones.available.names[substr(each.key, -1, 1) - 1]}"
    "kubernetes.io/cluster/${var.project}-cluster" = "shared"
    "kubernetes.io/role/internal-elb"              = 1
  }

  depends_on = [
    aws_vpc.main
  ]
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[data.aws_availability_zones.available.zone_ids[0]].id

  depends_on = [
    aws_eip.nat,
    aws_subnet.public
  ]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  depends_on = [
    aws_internet_gateway.igw
  ]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  depends_on = [
    aws_nat_gateway.nat
  ]
}

resource "aws_route_table_association" "public" {
  for_each = toset(data.aws_availability_zones.available.zone_ids)

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = toset(data.aws_availability_zones.available.zone_ids)

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private.id
}