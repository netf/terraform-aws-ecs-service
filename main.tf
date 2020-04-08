resource "aws_ecs_task_definition" "main" {
  family                   = "${var.environment}-${var.service_name}"
  container_definitions    = var.task_definition
  task_role_arn            = var.task_role_arn
  network_mode             = var.task_network_mode
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  requires_compatibilities = [var.service_launch_type]
  execution_role_arn       = var.awsvpc_task_execution_role_arn

  dynamic "volume" {
    for_each = [for v in var.task_volumes: {
      name = v.value.name
    }]
    content {
      name = volume.value.name
    }
  }
}

# Service for awsvpc networking and ALB
resource "aws_ecs_service" "awsvpc_alb" {
  count = var.task_network_mode == "awsvpc" && var.enable_lb ? 1 : 0

  name            = var.service_name
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.service_desired_count

  load_balancer {
    target_group_arn = aws_alb_target_group.main[0].arn
    container_name   = lookup(var.lb_target_group, "container_name", var.service_name)
    container_port   = lookup(var.lb_target_group, "container_port", 8080)
  }

  launch_type = var.service_launch_type

  network_configuration {
    security_groups = var.awsvpc_service_security_groups
    subnets         = var.awsvpc_service_subnetids
  }

  depends_on = ["aws_alb_listener.main"]
}

# Service for bridge networking and ALB
resource "aws_ecs_service" "bridge_alb" {
  count      = var.task_network_mode == "bridge" && var.enable_lb ? 1 : 0
  depends_on = ["aws_alb_listener.main"]

  name            = var.service_name
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.service_desired_count

  load_balancer {
    target_group_arn = aws_alb_target_group.main[0].arn
    container_name   = lookup(var.lb_target_group, "container_name", var.service_name)
    container_port   = lookup(var.lb_target_group, "container_port", 8080)
  }

  launch_type = var.service_launch_type

  iam_role = var.ecs_service_role
}

# Service for awsvpc networking and no ALB
resource "aws_ecs_service" "awsvpc_nolb" {
  count      = var.task_network_mode == "awsvpc" && !var.enable_lb ? 1 : 0
  depends_on = ["aws_alb_listener.main"]

  name            = var.service_name
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.service_desired_count

  network_configuration {
    security_groups = var.awsvpc_service_security_groups
    subnets         = var.awsvpc_service_subnetids
  }

  launch_type = var.service_launch_type
}

# Service for bridge networking and no ALB
resource "aws_ecs_service" "bridge_noalb" {
  count      = var.task_network_mode == "bridge" && !var.enable_lb ? 1 : 0
  depends_on = ["aws_alb_listener.main"]

  name            = var.service_name
  cluster         = var.ecs_cluster_id
  task_definition = aws_ecs_task_definition.main.arn
  desired_count   = var.service_desired_count

  launch_type = var.service_launch_type
}

# Load balancer

resource "aws_alb" "main" {
  count = var.enable_lb ? 1 : 0 ## Load Balancer

  name = "${var.environment}-${var.service_name}"

  internal        = var.lb_internal
  subnets         = var.lb_subnetids
  security_groups = concat(list(aws_security_group.alb_sg[0].id), var.lb_security_group_ids)

  tags = {
    Name        = "${var.environment}-${var.service_name}"
    Environment = var.environment
    Application = var.service_name
  }
}

resource "aws_alb_listener" "main" {
  count = var.enable_lb ? 1 : 0

  load_balancer_arn = aws_alb.main[0].id
  port              = lookup(var.lb_listener, "port")
  protocol          = lookup(var.lb_listener, "protocol", "HTTP")
  certificate_arn   = lookup(var.lb_listener, "certificate_arn", "")
  ssl_policy        = lookup(var.lb_listener, "certificate_arn", "") == "" ? "" : lookup(var.lb_listener, "ssl_policy", "ELBSecurityPolicy-TLS-1-1-2017-01")

  default_action {
    target_group_arn = aws_alb_target_group.main[0].id
    type             = "forward"
  }
}

resource "aws_alb_target_group" "main" {
  count = var.enable_lb ? 1 : 0

  name = "${var.environment}-${var.service_name}"

  port        = lookup(var.lb_target_group, "host_port", 80)
  protocol    = upper(lookup(var.lb_target_group, "protocol", "HTTP"))
  vpc_id      = var.vpc_id
  target_type = lookup(var.lb_target_group, "target_type", "ip")

  dynamic "health_check" {
    for_each = [for h in var.lb_health_check: {
      enabled             = h.enabled
      interval            = h.interval
      path                = h.path
      port                = h.port
      protocol            = h.protocol
      timeout             = h.timeout
      healthy_threshold   = h.healthy_threshold
      unhealthy_threshold = h.unhealthy_threshold
      matcher             = h.matcher
    }]
    content {
      enabled = health_check.value.enabled
      interval = health_check.value.interval
      path = health_check.value.path
      port = health_check.value.port
      protocol = health_check.value.protocol
      timeout = health_check.value.timeout
      healthy_threshold = health_check.value.healthy_threshold
      unhealthy_threshold = health_check.value.unhealthy_threshold
      matcher = health_check.value.matcher
    }
  }

  deregistration_delay = lookup(var.lb_target_group, "deregistration_delay", 300)

  tags = {
    Name        = "${var.environment}-${var.service_name}"
    Environment = var.environment
    Application = var.service_name
  }
}

resource "aws_security_group" "alb_sg" {
  count = var.enable_lb ? 1 : 0

  name        = "${var.environment}-${var.service_name}-alb-sg"
  description = "controls access to the application LB"

  vpc_id = var.vpc_id

  ingress {
    protocol    = "tcp"
    from_port   = lookup(var.lb_listener, "port", 80)
    to_port     = lookup(var.lb_listener, "port", 80)
    cidr_blocks = split(",",var.lb_internal ? var.vpc_cidr : join(",",var.public_alb_whitelist))
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.environment}-${var.service_name}-alb-sg"
    Environment = var.environment
    Application = var.service_name
  }
}